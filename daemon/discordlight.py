"""Discord Voice Lite daemon.

Headless discord.py-self client yang dikontrol oleh menu bar app lewat stdin/stdout
(JSON per baris). stdout = event ke UI, stderr = log.

Command (stdin):  {"cmd": "login", "token": "..."}
                  {"cmd": "join", "channel_id": "123"}
                  {"cmd": "leave"}
                  {"cmd": "mute", "on": true}
                  {"cmd": "deaf", "on": true}
                  {"cmd": "sensitivity", "rms": 200}
Arg:              path Unix socket untuk PCM (lihat AudioLink).
Event (stdout):   {"ev": "status"|"channels"|"voice"|"audio"|"error", ...}
"""

from __future__ import annotations

import asyncio
import audioop
import collections
import ctypes.util
import json
import logging
import os
import socket
import struct
import sys
import threading
import time
from typing import Any, Callable

import discord
from discord.ext.native_voice import BasicSink, MediaPacket, VoiceClient

log = logging.getLogger('discordlight')

SAMPLES_PER_FRAME = 960  # 20 ms @ 48 kHz
FRAME_BYTES = SAMPLES_PER_FRAME * 2 * 2  # stereo s16le
SILENCE = b'\x00' * FRAME_BYTES
SPEAKING_HOLD = 0.3  # detik
REORDER_DEPTH = 3  # paket (60 ms) yang ditunggu sebelum paket di celah dianggap hilang
MAX_CONCEAL = 6  # celah lebih panjang dari ini tidak di-PLC (hasilnya cuma dengung)
EXPECTED_LOSS = 0.15  # supaya encoder benar-benar menyisipkan FEC in-band

# Pemulihan koneksi voice (lihat Daemon._watchdog_loop).
WATCHDOG_INTERVAL = 2.0  # detik
RECOVER_GRACE = 12.0  # beri waktu library reconnect sendiri sebelum kita join ulang
REJOIN_MAX_ATTEMPTS = 6  # percobaan gagal (saat gateway hidup) sebelum menyerah
GATEWAY_BACKOFF_MAX_EXP = 5  # backoff reconnect gateway maks ~2^5 = 32 detik (default library ~17 menit)


class _CappedBackoff(discord.backoff.ExponentialBackoff):
    """Backoff reconnect gateway dengan batas atas kecil. Default discord.py bisa menunggu
    hingga ~17 menit setelah beberapa kali gagal (mis. Wi-Fi putus), sehingga app terlihat
    mati lama sekali setelah jaringan sudah kembali."""

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        super().__init__(*args, **kwargs)
        self._max = GATEWAY_BACKOFF_MAX_EXP


discord.client.ExponentialBackoff = _CappedBackoff  # type: ignore[misc]

# Frame di audio socket: [u8 type][u32 BE len][payload]
FRAME_PLAYBACK = 1  # daemon → UI: u32 BE ssrc + PCM s16le stereo 48 kHz
FRAME_MIC = 2  # UI → daemon: PCM s16le mono 48 kHz, 960 sample
HEADER = struct.Struct('>BI')


def load_opus() -> None:
    if discord.opus.is_loaded():
        return
    bundled = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'lib', 'libopus.0.dylib')
    for path in (bundled, ctypes.util.find_library('opus'), '/opt/homebrew/lib/libopus.dylib', '/usr/local/lib/libopus.dylib'):
        if not path:
            continue
        try:
            discord.opus.load_opus(path)
            return
        except OSError:
            continue
    raise RuntimeError('libopus tidak ditemukan (brew install opus)')


class AudioLink:
    """Unix socket ke menu bar app. Audio I/O (mic, speaker, echo cancellation) dikerjakan
    native oleh app lewat AVAudioEngine; daemon hanya bertukar PCM."""

    def __init__(self, path: str) -> None:
        self.on_mic: Callable[[bytes], None] | None = None
        self._conn: socket.socket | None = None
        self._send_lock = threading.Lock()
        if os.path.exists(path):
            os.unlink(path)
        self._server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._server.bind(path)
        self._server.listen(1)
        threading.Thread(target=self._accept_loop, name='audio-link', daemon=True).start()

    def _accept_loop(self) -> None:
        while True:
            conn, _ = self._server.accept()
            log.info('audio link connected')
            self._conn = conn
            try:
                self._read_loop(conn)
            except OSError:
                pass
            finally:
                self._conn = None
                conn.close()
                log.info('audio link closed')

    def _read_loop(self, conn: socket.socket) -> None:
        f = conn.makefile('rb')
        while header := f.read(HEADER.size):
            if len(header) < HEADER.size:
                return
            kind, length = HEADER.unpack(header)
            payload = f.read(length)
            if kind == FRAME_MIC and self.on_mic is not None:
                self.on_mic(payload)

    def send_playback(self, ssrc: int, pcm: bytes) -> None:
        conn = self._conn
        if conn is None:
            return
        data = HEADER.pack(FRAME_PLAYBACK, 4 + len(pcm)) + struct.pack('>I', ssrc) + pcm
        with self._send_lock:
            try:
                conn.sendall(data)
            except OSError:
                pass


class MicSource(discord.AudioSource):
    """PCM mic dari UI → Opus, dengan voice activity detection sederhana (RMS).

    Saat diam, player di-pause supaya indikator speaking mati dan Opus encoder tidak jalan.
    """

    def __init__(self, voice: VoiceClient, threshold: int) -> None:
        self.voice = voice
        self.threshold = threshold
        self.active = False
        self._hold_until = 0.0
        self._queue: collections.deque[bytes] = collections.deque(maxlen=10)
        self._preroll: collections.deque[bytes] = collections.deque(maxlen=3)

    def feed(self, mono: bytes) -> None:
        self._fed = getattr(self, '_fed', 0) + 1
        if self._fed % 250 == 1:
            log.info('mic frames=%d rms=%d threshold=%d active=%s', self._fed, audioop.rms(mono, 2), self.threshold, self.active)
        stereo = audioop.tostereo(mono, 2, 1, 1)
        now = time.monotonic()
        if audioop.rms(mono, 2) >= self.threshold:
            self._hold_until = now + SPEAKING_HOLD
        loud = now < self._hold_until

        if loud and not self.active:
            self.active = True
            self._queue.extend(self._preroll)
            self._preroll.clear()
            self.voice.resume()
        elif not loud and self.active:
            self.active = False
            self.voice.pause()
            self._queue.clear()

        (self._queue if self.active else self._preroll).append(stereo)

    def read(self) -> bytes:
        # Jangan pernah return b'' — itu akan menghentikan player.
        try:
            return self._queue.popleft()
        except IndexError:
            return SILENCE

    def is_opus(self) -> bool:
        return False


class OpusStream:
    """Decode Opus satu SSRC dengan reorder buffer kecil + pemulihan paket hilang.

    Paket yang berurutan langsung di-decode (tanpa tambahan latency). Kalau ada celah sequence,
    tunggu sampai REORDER_DEPTH paket sesudahnya datang; paket yang tetap hilang diisi dengan
    FEC in-band (paket tepat sebelum paket berikutnya) dan PLC Opus untuk sisanya.
    """

    def __init__(self) -> None:
        self.decoder = discord.opus.Decoder()
        self.expected: int | None = None  # sequence (unwrapped) berikutnya yang ditunggu
        self.pending: dict[int, bytes] = {}
        self.lost = 0
        self.late = 0

    def _unwrap(self, seq: int) -> int:
        delta = (seq - self.expected) & 0xFFFF
        return self.expected + delta if delta < 0x8000 else self.expected - (0x10000 - delta)

    def push(self, sequence: int, payload: bytes) -> list[bytes]:
        if self.expected is None:
            self.expected = sequence
        seq = self._unwrap(sequence)
        if seq < self.expected:
            self.late += 1  # sudah di-conceal, buang
            return []
        self.pending.setdefault(seq, payload)
        out: list[bytes] = []
        self._drain(out)
        if len(self.pending) >= REORDER_DEPTH:
            self._skip_gap(out)
            self._drain(out)
        return out

    def _decode(self, out: list[bytes], payload: bytes | None, fec: bool = False) -> None:
        try:
            pcm = self.decoder.decode(payload, fec=fec)
        except Exception:
            log.debug('opus decode gagal', exc_info=True)
            return
        if pcm:
            out.append(pcm)

    def _drain(self, out: list[bytes]) -> None:
        while (payload := self.pending.pop(self.expected, None)) is not None:
            self._decode(out, payload)
            self.expected += 1

    def _skip_gap(self, out: list[bytes]) -> None:
        first = min(self.pending)
        missing = first - self.expected
        self.lost += missing
        if missing <= MAX_CONCEAL:
            for _ in range(missing - 1):
                self._decode(out, None)
            self._decode(out, self.pending[first], fec=True)
        self.expected = first


class Receiver:
    """Decode audio per user lalu meneruskan PCM ke UI (mixing & jitter buffer di sisi native),
    dan mencatat siapa yang bicara."""

    def __init__(self, link: AudioLink) -> None:
        self.link = link
        self.last_speaking: dict[int, float] = {}  # user_id -> monotonic
        self.streams: dict[int, OpusStream] = {}
        self.count = 0

    def write(self, packet: MediaPacket) -> None:
        self.count += 1
        if packet.codec != 'opus':
            return
        stream = self.streams.get(packet.ssrc)
        if stream is None:
            stream = self.streams[packet.ssrc] = OpusStream()
        if self.count % 500 == 1:
            log.info('received packets=%d lost=%d late=%d link=%s', self.count, stream.lost, stream.late, self.link._conn is not None)
        for pcm in stream.push(packet.sequence, packet.payload):
            self.link.send_playback(packet.ssrc, pcm)
        if packet.user_id is not None and (packet.audio_level is None or packet.audio_level < 127):
            self.last_speaking[packet.user_id] = time.monotonic()


class Daemon:
    def __init__(self, audio_socket: str) -> None:
        self.loop = asyncio.get_running_loop()
        self.client = discord.Client(max_messages=None, chunk_guilds_at_startup=False)
        self.voice: VoiceClient | None = None
        self.mic: MicSource | None = None
        self.receiver: Receiver | None = None
        self.link = AudioLink(audio_socket)
        self.link.on_mic = self._on_mic
        self._audio_state: tuple[bool, bool] | None = None
        self.muted = False
        self.deafened = False
        self.threshold = 200
        self._channels_dirty = asyncio.Event()
        self._last_voice_payload: str | None = None
        self._lock = asyncio.Lock()
        # Channel yang user inginkan; None = user memang tidak di voice. Selama ini tidak None,
        # watchdog akan memulihkan koneksi yang putus.
        self.want_channel: int | None = None
        self._gateway_up = False
        self._down_since: float | None = None
        self._next_rejoin = 0.0
        self._rejoin_attempts = 0

        self.client.event(self.on_ready)
        self.client.event(self.on_connect)
        self.client.event(self.on_resumed)
        self.client.event(self.on_disconnect)
        self.client.event(self.on_voice_state_update)

    # ---------- output ----------

    def emit(self, ev: str, **data: Any) -> None:
        sys.stdout.write(json.dumps({'ev': ev, **data}, ensure_ascii=False) + '\n')
        sys.stdout.flush()

    # ---------- discord events ----------

    async def on_ready(self) -> None:
        user = self.client.user
        log.info('logged in as %s', user)
        self.emit('status', state='ready', user=str(user), user_id=str(user.id))
        self._channels_dirty.set()

    async def on_connect(self) -> None:
        self._gateway_up = True

    async def on_resumed(self) -> None:
        self._gateway_up = True
        log.info('gateway resumed')

    async def on_disconnect(self) -> None:
        if self._gateway_up:
            log.warning('gateway terputus')
        self._gateway_up = False

    async def on_voice_state_update(self, member: discord.Member, before: Any, after: Any) -> None:
        self._channels_dirty.set()
        if member.id == self.client.user.id:
            if after.channel is not None and self.want_channel is not None:
                # Dipindah orang lain → ikuti channel barunya.
                self.want_channel = after.channel.id
            elif after.channel is None and self.want_channel is not None:
                # Bisa kick, tapi juga bisa bagian dari reconnect internal library (ia mengirim
                # channel=None lalu join lagi). Jangan teardown di sini; watchdog yang memutuskan.
                log.info('voice state: channel kosong; menunggu reconnect')
        self._emit_voice(force=True)

    # ---------- snapshots ----------

    def _member_name(self, guild: discord.Guild, user_id: int) -> str:
        m = guild.get_member(user_id)
        if m is not None:
            return m.display_name
        u = self.client.get_user(user_id)
        return u.display_name if u is not None else str(user_id)

    def _channels_snapshot(self) -> list[dict[str, Any]]:
        guilds = []
        for guild in self.client.guilds:
            channels = []
            for ch in list(guild.voice_channels) + list(guild.stage_channels):
                try:
                    if guild.me is not None and not ch.permissions_for(guild.me).connect:
                        continue
                except Exception:
                    pass
                members = [self._member_name(guild, uid) for uid in ch.voice_states]
                channels.append({'id': str(ch.id), 'name': ch.name, 'members': members})
            if channels:
                channels.sort(key=lambda c: c['name'].lower())
                guilds.append({'id': str(guild.id), 'name': guild.name, 'channels': channels})
        return guilds

    async def _channels_loop(self) -> None:
        while True:
            await self._channels_dirty.wait()
            await asyncio.sleep(1)  # debounce
            self._channels_dirty.clear()
            if self.client.is_ready():
                self.emit('channels', guilds=self._channels_snapshot())

    def _emit_voice(self, force: bool = False) -> None:
        voice = self.voice
        connected = bool(voice and voice.is_connected())
        payload: dict[str, Any] = {
            'connected': connected,
            'connecting': not connected and self.want_channel is not None,
            'muted': self.muted or self.deafened,
            'deafened': self.deafened,
        }
        if voice is not None and voice.channel is not None:
            ch = voice.channel
            now = time.monotonic()
            speaking = self.receiver.last_speaking if self.receiver else {}
            me = self.client.user.id
            members = []
            for uid, vs in ch.voice_states.items():
                is_me = uid == me
                talking = (self.mic is not None and self.mic.active) if is_me else now - speaking.get(uid, 0) < SPEAKING_HOLD
                members.append({
                    'name': self._member_name(ch.guild, uid),
                    'me': is_me,
                    'muted': bool(vs.self_mute or vs.mute),
                    'deafened': bool(vs.self_deaf or vs.deaf),
                    'speaking': bool(talking),
                })
            members.sort(key=lambda m: m['name'].lower())
            payload.update(channel={'id': str(ch.id), 'name': ch.name, 'guild': ch.guild.name}, members=members)
        text = json.dumps(payload, sort_keys=True)
        if force or text != self._last_voice_payload:
            self._last_voice_payload = text
            self.emit('voice', **payload)

    async def _voice_loop(self) -> None:
        # Polling ringan untuk indikator speaking; hanya emit kalau ada perubahan.
        while True:
            await asyncio.sleep(0.25)
            if self.voice is not None or self.want_channel is not None:
                self._emit_voice()

    async def _watchdog_loop(self) -> None:
        while True:
            await asyncio.sleep(WATCHDOG_INTERVAL)
            try:
                await self._watchdog_tick()
            except Exception:
                log.exception('watchdog error')

    async def _watchdog_tick(self) -> None:
        """Pulihkan voice yang putus tanpa user menekan Disconnect.

        discord.py mencoba reconnect sendiri (resume / connect ulang). Kalau berhasil, player &
        sink di-restart supaya audio jalan lagi. Kalau setelah RECOVER_GRACE masih putus (resume
        timeout, sesi gateway baru setelah IDENTIFY ulang, kick, dsb.), kita join ulang sendiri.
        """
        want = self.want_channel
        if want is None or self._lock.locked():
            self._down_since = None
            return
        voice = self.voice
        now = time.monotonic()
        if voice is not None and voice.is_connected():
            if self._down_since is not None:
                log.info('voice pulih sendiri setelah %.1fs; restart audio', now - self._down_since)
                self._down_since = None
                self._rejoin_attempts = 0
                async with self._lock:
                    await self._restart_audio()
                self._emit_voice(force=True)
            return

        if self._down_since is None:
            log.warning('voice terputus; menunggu reconnect library')
            self._down_since = now
            self._emit_voice(force=True)
            return
        if now - self._down_since < RECOVER_GRACE or now < self._next_rejoin or not self._gateway_up:
            return

        self._rejoin_attempts += 1
        log.warning('join ulang otomatis (percobaan %d)', self._rejoin_attempts)
        if await self._rejoin(want):
            log.info('join ulang berhasil')
            self._down_since = None
            self._rejoin_attempts = 0
        elif self._rejoin_attempts >= REJOIN_MAX_ATTEMPTS or self.client.get_channel(want) is None:
            log.warning('menyerah join ulang')
            async with self._lock:
                self.want_channel = None
                await self._drop_voice()
            self._down_since = None
            self._rejoin_attempts = 0
            self.emit('error', message='Koneksi voice terputus dan gagal tersambung ulang')
            self._emit_voice(force=True)
        else:
            self._next_rejoin = now + min(60.0, 5.0 * 2 ** (self._rejoin_attempts - 1))

    async def _rejoin(self, channel_id: int) -> bool:
        channel = self.client.get_channel(channel_id)
        if not isinstance(channel, (discord.VoiceChannel, discord.StageChannel)):
            return False
        async with self._lock:
            if self.want_channel != channel_id:
                return True  # user sudah memilih hal lain sementara itu
            await self._connect_channel(channel, report_error=False)
            return self.voice is not None and self.voice.is_connected()

    # ---------- audio ----------

    def _on_mic(self, mono: bytes) -> None:
        mic = self.mic
        if mic is not None:
            mic.feed(mono)

    def _emit_audio(self, mic: bool, speaker: bool) -> None:
        # Minta UI menyalakan/mematikan AVAudioEngine (mic + echo cancellation / speaker saja).
        if self._audio_state != (mic, speaker):
            self._audio_state = (mic, speaker)
            log.info('audio state mic=%s speaker=%s', mic, speaker)
            self.emit('audio', mic=mic, speaker=speaker)

    async def _apply_audio(self) -> None:
        voice = self.voice
        if voice is None or not voice.is_connected():
            return
        want_speaker = not self.deafened
        want_mic = not self.muted and not self.deafened

        if want_speaker and self.receiver is None:
            self.receiver = Receiver(self.link)
            voice.listen(BasicSink(self.receiver.write, media_types=['audio'], codecs=['opus']))
        elif not want_speaker and self.receiver is not None:
            if voice.is_listening():
                voice.stop_listening()
            self.receiver = None

        if want_mic and self.mic is None:
            self.mic = MicSource(voice, self.threshold)
            voice.play(self.mic, application='voip', expected_packet_loss=EXPECTED_LOSS)
            voice.pause()
        elif not want_mic and self.mic is not None:
            voice.stop()
            self.mic = None

        self._emit_audio(want_mic, want_speaker)

    async def _restart_audio(self) -> None:
        # Setelah library reconnect, player & sink lama belum tentu masih hidup → buat ulang.
        # Tidak lewat _teardown_audio supaya AVAudioEngine di UI tidak ikut dimatikan.
        voice = self.voice
        if voice is not None:
            if voice.is_listening():
                voice.stop_listening()
            voice.stop()
        self.receiver = None
        self.mic = None
        await self._apply_audio()

    async def _teardown_audio(self) -> None:
        voice = self.voice
        if voice is not None:
            if voice.is_listening():
                voice.stop_listening()
            voice.stop()
        self.receiver = None
        self.mic = None
        self._emit_audio(False, False)

    # ---------- commands ----------

    async def cmd_login(self, token: str) -> None:
        self.emit('status', state='connecting')
        asyncio.create_task(self._run_client(token))

    async def _run_client(self, token: str) -> None:
        try:
            await self.client.start(token)
        except discord.LoginFailure:
            self.emit('status', state='bad_token')
        except Exception as e:
            log.exception('client stopped')
            self.emit('error', message=f'Client berhenti: {e}')

    async def cmd_join(self, channel_id: str) -> None:
        channel = self.client.get_channel(int(channel_id))
        if not isinstance(channel, (discord.VoiceChannel, discord.StageChannel)):
            self.emit('error', message='Channel tidak ditemukan')
            return
        async with self._lock:
            self.want_channel = channel.id
            self._down_since = None
            self._rejoin_attempts = 0
            if self.voice is not None and self.voice.is_connected():
                if self.voice.channel and self.voice.channel.guild == channel.guild:
                    await self.voice.move_to(channel)
                    self._emit_voice(force=True)
                    return
            if not await self._connect_channel(channel, report_error=True):
                self.want_channel = None
                self._emit_voice(force=True)

    async def _connect_channel(self, channel: discord.VoiceChannel | discord.StageChannel, *, report_error: bool) -> bool:
        """Join channel dari nol (harus dipanggil dengan self._lock dipegang)."""
        await self._drop_voice()
        self.emit('voice', connected=False, connecting=True, muted=self.muted or self.deafened, deafened=self.deafened)
        try:
            self.voice = await channel.connect(
                cls=VoiceClient, self_mute=self.muted or self.deafened, self_deaf=self.deafened
            )
        except Exception as e:
            log.exception('join failed')
            self.voice = None
            # Bersihkan voice client setengah jadi supaya percobaan berikutnya tidak kena
            # "Already connected to a voice channel".
            await self._drop_voice()
            if report_error:
                self.emit('error', message=f'Gagal join: {e}')
            self._emit_voice(force=True)
            return False
        await self._apply_audio()
        self._emit_voice(force=True)
        return True

    async def _drop_voice(self) -> None:
        """Putuskan semua voice client, termasuk yang masih nyangkut di loop reconnect library."""
        await self._teardown_audio()
        clients = list(self.client.voice_clients)
        if self.voice is not None and self.voice not in clients:
            clients.append(self.voice)
        for vc in clients:
            # disconnect() tidak membatalkan poller websocket; poller yang sedang di loop
            # reconnect bisa join lagi memakai client lama dan bentrok dengan join baru.
            conn = getattr(vc, '_connection', None)
            runner = getattr(conn, '_runner', None)
            if runner is not None:
                runner.cancel()
                conn._runner = None
            try:
                await vc.disconnect(force=True)
            except Exception:
                log.warning('gagal disconnect voice client lama', exc_info=True)
        self.voice = None

    async def cmd_leave(self) -> None:
        async with self._lock:
            self.want_channel = None
            self._down_since = None
            if self.voice is not None:
                await self._drop_voice()
            self._emit_voice(force=True)

    async def _set_flags(self, muted: bool, deafened: bool) -> None:
        self.muted, self.deafened = muted, deafened
        voice = self.voice
        if voice is not None and voice.is_connected() and voice.channel is not None:
            await voice.channel.guild.change_voice_state(
                channel=voice.channel, self_mute=muted or deafened, self_deaf=deafened
            )
            await self._apply_audio()
        self._emit_voice(force=True)

    async def handle(self, msg: dict[str, Any]) -> None:
        cmd = msg.get('cmd')
        if cmd == 'login':
            await self.cmd_login(msg['token'])
        elif cmd == 'join':
            await self.cmd_join(msg['channel_id'])
        elif cmd == 'leave':
            await self.cmd_leave()
        elif cmd == 'mute':
            on = bool(msg['on'])
            # Unmute saat deafen = undeafen juga (perilaku Discord).
            await self._set_flags(on, self.deafened and on)
        elif cmd == 'deaf':
            # Deafen tidak mengubah pilihan mute; setelah undeafen, mute kembali ke kondisi sebelumnya.
            await self._set_flags(self.muted, bool(msg['on']))
        elif cmd == 'sensitivity':
            self.threshold = int(msg['rms'])
            if self.mic is not None:
                self.mic.threshold = self.threshold
        elif cmd == 'state':
            self._channels_dirty.set()
            self._emit_voice(force=True)
        else:
            self.emit('error', message=f'Command tidak dikenal: {cmd}')

    async def run(self) -> None:
        reader = asyncio.StreamReader()
        await self.loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), sys.stdin)
        asyncio.create_task(self._channels_loop())
        asyncio.create_task(self._voice_loop())
        asyncio.create_task(self._watchdog_loop())
        self.emit('status', state='need_token')
        while line := await reader.readline():
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            try:
                await self.handle(msg)
            except Exception as e:
                log.exception('command failed: %s', msg.get('cmd'))
                self.emit('error', message=str(e))
        # stdin ditutup = UI app keluar.
        await self.cmd_leave()
        await self.client.close()


async def main() -> None:
    logging.basicConfig(level=logging.INFO, stream=sys.stderr, format='%(asctime)s %(levelname)s %(name)s: %(message)s')
    logging.getLogger('discord').setLevel(logging.WARNING)
    # Alur reconnect voice dicatat di INFO; perlu untuk diagnosa putus-sambung.
    logging.getLogger('discord.voice_state').setLevel(logging.INFO)
    load_opus()
    if len(sys.argv) < 2:
        sys.exit('usage: discordlight.py <audio-socket-path>')
    await Daemon(sys.argv[1]).run()


if __name__ == '__main__':
    asyncio.run(main())
