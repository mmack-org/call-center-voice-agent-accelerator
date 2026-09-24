"""Base handler for Azure Voice Live API connections using the official SDK.

Provides the shared Voice Live connection, event processing, web client
audio handling with ambient mixing, and cleanup logic. Telephony subclasses
override on_message() and hook methods to implement protocol-specific behavior.
"""

import asyncio
import base64
import json
import logging
import time
from typing import Optional, Union

import numpy as np
from azure.core.credentials import AzureKeyCredential
from azure.identity.aio import ManagedIdentityCredential
from azure.ai.voicelive.aio import connect as voicelive_connect
from azure.ai.voicelive.models import (
    AudioEchoCancellation,
    AudioNoiseReduction,
    AzureSemanticVad,
    AzureStandardVoice,
    InputAudioFormat,
    Modality,
    OutputAudioFormat,
    RequestSession,
    ServerEventType,
)

from .ambient_mixer import AmbientMixer
from ..fabric_tools import FabricHttpBackend, FabricToolService

# Data type for WebSocket messages (str or bytes) sent to client
Data = Union[str, bytes]

logger = logging.getLogger(__name__)
telemetry_logger = logging.getLogger("telemetry.voicelive")

# Default chunk size in bytes (100ms of audio at 24kHz, 16-bit mono)
DEFAULT_CHUNK_SIZE = 4800  # 24000 samples/sec * 0.1 sec * 2 bytes
DEFAULT_VOICE = "fr-FR-DeniseNeural"
DIRECT_MODEL_INSTRUCTIONS = (
    "Vous êtes un agent de support de centre d'appels. Répondez en français "
    "par défaut, de façon claire, concise, naturelle et adaptée à un échange "
    "téléphonique. Posez une question de clarification lorsque la demande est "
    "ambiguë et n'inventez pas d'information."
)


class VoiceLiveMediaHandler:
    """Handles the connection to Azure Voice Live API and web clients.

    Uses the azure-ai-voicelive SDK for typed session config, event handling,
    and audio streaming. Provides web client audio handling (raw PCM + ambient
    mixing) by default. Telephony subclasses override on_message() and hooks
    for their specific protocols.
    """

    def __init__(self, config):
        self.endpoint = config["AZURE_VOICE_LIVE_ENDPOINT"]
        self.model = config["VOICE_LIVE_MODEL"]
        self.api_key = config["AZURE_VOICE_LIVE_API_KEY"]
        self.client_id = config["AZURE_USER_ASSIGNED_IDENTITY_CLIENT_ID"]
        self.foundry_iq_enabled = (
            str(config.get("ENABLE_FOUNDRY_IQ", "false")).lower() == "true"
        )
        self.foundry_project_name = config.get("AZURE_AI_FOUNDRY_PROJECT_NAME", "")
        self.foundry_agent_name = config.get("AZURE_AI_FOUNDRY_AGENT_ID", "")
        self.authorized_customer_key = config.get("AUTHORIZED_CUSTOMER_KEY", "")
        self.fabric_tools = None
        if (
            config.get("FABRIC_WORKSPACE_ID")
            and config.get("FABRIC_LAKEHOUSE_ID")
            and config.get("FABRIC_DATA_AGENT_ID")
            and config.get("FABRIC_READ_IDENTITY_CLIENT_ID")
            and config.get("FABRIC_WRITE_IDENTITY_CLIENT_ID")
        ):
            self.fabric_tools = FabricToolService(
                FabricHttpBackend(
                    workspace_id=config["FABRIC_WORKSPACE_ID"],
                    lakehouse_id=config["FABRIC_LAKEHOUSE_ID"],
                    data_agent_id=config["FABRIC_DATA_AGENT_ID"],
                    ticket_write_endpoint=config.get(
                        "FABRIC_TICKET_WRITE_ENDPOINT", ""
                    ),
                    read_client_id=config["FABRIC_READ_IDENTITY_CLIENT_ID"],
                    write_client_id=config["FABRIC_WRITE_IDENTITY_CLIENT_ID"],
                )
            )
        self.voice = config.get("VOICE_LIVE_VOICE", DEFAULT_VOICE)
        self.conn = None
        self._conn_ctx = None  # async context manager from SDK connect()
        self._credential = None  # kept alive for token refresh
        self._receiver_task = None
        self._voicelive_connected = False  # True while Voice Live WS is healthy
        self._response_started_at = None
        self._tool_started_at = None

        # Client WebSocket
        self.client_ws = None

        # TTS output buffering for continuous ambient mixing
        self._tts_output_buffer = bytearray()
        self._tts_buffer_lock = asyncio.Lock()
        self._max_buffer_size = 480000  # 10 seconds of audio
        self._buffer_warning_logged = False
        self._tts_playback_started = False
        self._min_buffer_to_start = 9600  # 200ms buffer before starting TTS playback

        # Ambient mixer initialization
        self._ambient_mixer: Optional[AmbientMixer] = None
        ambient_preset = config.get("AMBIENT_PRESET", "none")
        if ambient_preset and ambient_preset != "none":
            try:
                self._ambient_mixer = AmbientMixer(preset=ambient_preset)
            except Exception as e:
                logger.error(f"Failed to initialize AmbientMixer: {e}")

    def _session_config(self) -> RequestSession:
        """Return the typed session configuration for Voice Live."""
        options = {
            "modalities": [Modality.TEXT, Modality.AUDIO],
            "turn_detection": AzureSemanticVad(),
            "input_audio_format": InputAudioFormat.PCM16,
            "output_audio_format": OutputAudioFormat.PCM16,
            "input_audio_noise_reduction": AudioNoiseReduction(
                type="azure_deep_noise_suppression"
            ),
            "input_audio_echo_cancellation": AudioEchoCancellation(),
            "voice": AzureStandardVoice(name=self.voice, temperature=0.8),
        }
        if not self.foundry_iq_enabled:
            options["instructions"] = DIRECT_MODEL_INSTRUCTIONS

        return RequestSession(
            **options,
        )

    @staticmethod
    def _mcp_result_count(output: str | None) -> int:
        """Count result containers in an MCP response without logging their content."""
        if not output:
            return 0
        try:
            pending = [json.loads(output)]
        except (TypeError, json.JSONDecodeError):
            return -1

        result_keys = {"results", "documents", "references", "citations"}
        while pending:
            value = pending.pop()
            if isinstance(value, dict):
                for key, child in value.items():
                    if key.lower() in result_keys and isinstance(child, list):
                        return len(child)
                    if isinstance(child, (dict, list)):
                        pending.append(child)
            elif isinstance(value, list):
                pending.extend(value)
        return -1

    def _log_tool_event(
        self, event, event_name: str, result_count: int | None = None
    ) -> None:
        """Log tool timing and outcome metadata without recording retrieved content."""
        normalized = event_name.lower()
        if "in_progress" in normalized:
            self._tool_started_at = time.perf_counter()

        status = "failed" if getattr(event, "error", None) is not None else "observed"
        if "done" in normalized or "completed" in normalized:
            status = "succeeded" if status != "failed" else status

        if result_count is None:
            result_count = getattr(event, "result_count", -1)
        if not isinstance(result_count, int):
            result_count = -1
        duration_ms = (
            (time.perf_counter() - self._tool_started_at) * 1000
            if self._tool_started_at
            else 0
        )
        empty = result_count == 0 if result_count >= 0 else "unknown"
        telemetry_logger.info(
            "[VoiceLive] foundry_iq_tool event=%s status=%s duration_ms=%.0f result_count=%s empty=%s",
            event_name,
            status,
            duration_ms,
            result_count,
            empty,
        )

        if "done" in normalized or "completed" in normalized or status == "failed":
            self._tool_started_at = None

    # ------------------------------------------------------------------
    # Voice Live connection
    # ------------------------------------------------------------------

    async def connect_voicelive(self):
        """Connect to Azure Voice Live API using the SDK."""
        t0 = time.perf_counter()

        if self.client_id:
            self._credential = ManagedIdentityCredential(client_id=self.client_id)
            credential = self._credential
        else:
            credential = AzureKeyCredential(self.api_key)

        t1 = time.perf_counter()
        logger.info("[VoiceLive] Credential prepared in %.2fs", t1 - t0)

        connection_options = {
            "endpoint": self.endpoint,
            "credential": credential,
        }
        if self.foundry_iq_enabled:
            connection_options.update(
                agent_name=self.foundry_agent_name,
                project_name=self.foundry_project_name,
                api_version="2026-07-15",
            )
            logger.info(
                "[VoiceLive] agent_invocation status=starting agent=%s project=%s",
                self.foundry_agent_name,
                self.foundry_project_name,
            )
            telemetry_logger.info(
                "[VoiceLive] agent_invocation status=starting agent=%s project=%s",
                self.foundry_agent_name,
                self.foundry_project_name,
            )
        else:
            connection_options["model"] = self.model.strip()

        try:
            self._conn_ctx = voicelive_connect(**connection_options)
            self.conn = await self._conn_ctx.__aenter__()
        except Exception:
            if self.foundry_iq_enabled:
                logger.exception(
                    "[VoiceLive] agent_invocation status=failed duration_ms=%.0f",
                    (time.perf_counter() - t1) * 1000,
                )
                telemetry_logger.error(
                    "[VoiceLive] agent_invocation status=failed duration_ms=%.0f",
                    (time.perf_counter() - t1) * 1000,
                )
            raise

        t2 = time.perf_counter()
        logger.info("[VoiceLive] SDK connected in %.2fs (total %.2fs)", t2 - t1, t2 - t0)
        if self.foundry_iq_enabled:
            telemetry_logger.info(
                "[VoiceLive] agent_invocation status=succeeded duration_ms=%.0f",
                (t2 - t1) * 1000,
            )
        self._voicelive_connected = True

        await self.conn.session.update(session=self._session_config())
        await self.conn.response.create()

        self._receiver_task = asyncio.create_task(self._receiver_loop())

    async def send_audio(self, audio_b64: str):
        """Send PCM 24kHz 16-bit mono audio (base64) to Voice Live."""
        if not self._voicelive_connected:
            return
        await self.conn.input_audio_buffer.append(audio=audio_b64)

    async def _receiver_loop(self):
        """Receives typed events from Voice Live and dispatches to hook methods."""
        cancelled = False
        try:
            async for event in self.conn:
                event_type = event.type

                match event_type:
                    case ServerEventType.SESSION_CREATED:
                        session_id = event.session.id if hasattr(event, "session") else None
                        logger.info("[VoiceLive] Session ID: %s", session_id)

                    case ServerEventType.SESSION_UPDATED:
                        logger.info("[VoiceLive] Session updated")

                    case ServerEventType.INPUT_AUDIO_BUFFER_CLEARED:
                        logger.debug("[VoiceLive] Input audio buffer cleared")

                    case ServerEventType.INPUT_AUDIO_BUFFER_SPEECH_STARTED:
                        logger.info(
                            "[VoiceLive] Speech started at %s ms",
                            event.audio_start_ms,
                        )
                        await self.on_speech_started()

                    case ServerEventType.INPUT_AUDIO_BUFFER_SPEECH_STOPPED:
                        logger.info("[VoiceLive] Speech stopped")
                        self._response_started_at = time.perf_counter()

                    case ServerEventType.CONVERSATION_ITEM_INPUT_AUDIO_TRANSCRIPTION_COMPLETED:
                        transcript = event.transcript
                        logger.debug("[VoiceLive] User: %s", transcript)

                    case ServerEventType.CONVERSATION_ITEM_INPUT_AUDIO_TRANSCRIPTION_FAILED:
                        logger.warning(
                            "[VoiceLive] Transcription error: %s", event.error if hasattr(event, "error") else "unknown"
                        )

                    case ServerEventType.RESPONSE_AUDIO_DELTA:
                        delta = event.delta
                        if delta:
                            await self.on_audio_delta(delta)

                    case ServerEventType.RESPONSE_AUDIO_TRANSCRIPT_DONE:
                        transcript = event.transcript
                        logger.debug("[VoiceLive] AI: %s", transcript)
                        await self.on_transcript_done(transcript)

                    case ServerEventType.RESPONSE_OUTPUT_ITEM_DONE:
                        item = getattr(event, "item", None)
                        if item and "mcp_call" in str(getattr(item, "type", "")).lower():
                            self._log_tool_event(
                                item,
                                "response.mcp_call.output",
                                self._mcp_result_count(getattr(item, "output", None)),
                            )

                    case ServerEventType.RESPONSE_DONE:
                        response_id = event.response.id if hasattr(event, "response") else None
                        logger.info(
                            "[VoiceLive] Response done: id=%s end_to_end_latency_ms=%.0f",
                            response_id,
                            (time.perf_counter() - self._response_started_at) * 1000
                            if self._response_started_at
                            else 0,
                        )
                        telemetry_logger.info(
                            "[VoiceLive] response status=completed end_to_end_latency_ms=%.0f",
                            (time.perf_counter() - self._response_started_at) * 1000
                            if self._response_started_at
                            else 0,
                        )
                        self._response_started_at = None

                    case ServerEventType.ERROR:
                        logger.error("[VoiceLive] Error: %s", event.error)

                    case _:
                        event_name = str(event_type)
                        if "function_call_arguments_done" in event_name.lower():
                            await self._handle_function_call(event)
                        elif "mcp" in event_name.lower() or "tool" in event_name.lower():
                            self._log_tool_event(event, event_name)
                        else:
                            logger.debug("[VoiceLive] Event: %s", event_type)
        except asyncio.CancelledError:
            cancelled = True
            raise
        except Exception:
            logger.exception("[VoiceLive] Receiver loop error")
        finally:
            self._voicelive_connected = False
            # If Voice Live dropped unexpectedly (not a normal cancellation),
            # close the client WebSocket so the caller-side loop exits cleanly.
            if not cancelled and self.client_ws:
                try:
                    logger.warning("[VoiceLive] Voice Live disconnected — closing client WebSocket")
                    await self.client_ws.close(1001)  # Going Away
                except Exception:
                    pass

    # ------------------------------------------------------------------
    # Client WebSocket
    # ------------------------------------------------------------------

    async def init_websocket(self, socket):
        """Sets up the client WebSocket."""
        self.client_ws = socket

    async def _handle_function_call(self, event) -> None:
        """Execute the only supported write tool and return its result to the agent."""
        name = getattr(event, "name", "")
        call_id = getattr(event, "call_id", "")
        if name not in {
            "fabric_retrieve_business_data",
            "create_support_ticket",
        }:
            logger.warning("[VoiceLive] Rejected unsupported function tool=%s", name)
            return
        if not self.fabric_tools or not self.authorized_customer_key:
            result = {"error": "This Fabric tool is unavailable for this authenticated session."}
        else:
            try:
                arguments = json.loads(getattr(event, "arguments", "{}"))
                if name == "fabric_retrieve_business_data":
                    result = await self.fabric_tools.retrieve(
                        **arguments,
                        authorized_customer_key=self.authorized_customer_key,
                        correlation_id=call_id,
                    )
                else:
                    result = await self.fabric_tools.create_ticket(
                        arguments,
                        authorized_customer_key=self.authorized_customer_key,
                        actor_id=self.client_id,
                        correlation_id=call_id,
                    )
            except Exception as exc:
                logger.warning(
                    "[VoiceLive] tool=%s rejected error=%s",
                    name,
                    type(exc).__name__,
                )
                result = {"error": "The requested Fabric operation was not completed."}
        await self.conn.conversation.item.create(
            item={
                "type": "function_call_output",
                "call_id": call_id,
                "output": json.dumps(result),
            }
        )
        await self.conn.response.create()

    async def send_message(self, message: Data):
        """Sends data back to client WebSocket."""
        try:
            await self.client_ws.send(message)
        except Exception:
            logger.exception("[VoiceLive] Failed to send message to client")

    # ------------------------------------------------------------------
    # Hooks — web client implementations (override in telephony subclasses)
    # ------------------------------------------------------------------

    async def on_speech_started(self):
        """Barge-in: send StopAudio to client and clear TTS buffer."""
        stop_audio_data = {"Kind": "StopAudio", "AudioData": None, "StopAudio": {}}
        await self.send_message(json.dumps(stop_audio_data))

        if self._ambient_mixer is not None:
            async with self._tts_buffer_lock:
                self._tts_output_buffer.clear()
                self._tts_playback_started = False

    async def on_audio_delta(self, audio_bytes: bytes):
        """Handle audio from Voice Live — buffer for ambient or send directly."""
        if self._ambient_mixer is not None and self._ambient_mixer.is_enabled():
            async with self._tts_buffer_lock:
                self._tts_output_buffer.extend(audio_bytes)
                if len(self._tts_output_buffer) > self._max_buffer_size:
                    if not self._buffer_warning_logged:
                        logger.warning(
                            f"TTS buffer large: {len(self._tts_output_buffer)} bytes. "
                            "Speech may be delayed but will not be cut."
                        )
                        self._buffer_warning_logged = True
                elif self._buffer_warning_logged and len(self._tts_output_buffer) < self._max_buffer_size // 2:
                    self._buffer_warning_logged = False
        else:
            await self._send_audio_to_client(audio_bytes)

    async def on_transcript_done(self, transcript: str):
        """Forward transcript to client."""
        await self.send_message(
            json.dumps({"Kind": "Transcription", "Text": transcript})
        )

    # ------------------------------------------------------------------
    # Audio output to client
    # ------------------------------------------------------------------

    async def _send_audio_to_client(self, audio_bytes: bytes):
        """Send audio bytes to the client. Override in subclasses for wrapping."""
        await self.send_message(audio_bytes)

    # ------------------------------------------------------------------
    # Inbound audio from client
    # ------------------------------------------------------------------

    def _receive_audio_from_client(self, data) -> tuple:
        """Convert client audio to PCM 24kHz. Override for format conversion.

        Returns (pcm_bytes | None, chunk_size). Return None for silent frames.
        """
        return data, len(data)

    async def on_message(self, msg):
        """Process one incoming WebSocket message. Override in subclasses for protocol handling."""
        await self.handle_audio(msg)

    async def handle_audio(self, data):
        """Process inbound audio: convert, mix ambient, forward to Voice Live."""
        pcm_bytes, chunk_size = self._receive_audio_from_client(data)
        await self._send_continuous_audio(chunk_size)
        if pcm_bytes:
            audio_b64 = base64.b64encode(pcm_bytes).decode("ascii")
            await self.send_audio(audio_b64)

    # ------------------------------------------------------------------
    # Ambient mixing
    # ------------------------------------------------------------------

    async def _send_continuous_audio(self, chunk_size: int) -> None:
        """Send continuous audio (ambient + TTS if available) back to client."""
        if self._ambient_mixer is None or not self._ambient_mixer.is_enabled():
            return

        try:
            async with self._tts_buffer_lock:
                buffer_len = len(self._tts_output_buffer)
                ambient_bytes = self._ambient_mixer.get_ambient_only_chunk(chunk_size)

                should_play_tts = False
                if self._tts_playback_started:
                    if buffer_len >= chunk_size:
                        should_play_tts = True
                    elif buffer_len > 0:
                        should_play_tts = True
                    else:
                        self._tts_playback_started = False
                else:
                    if buffer_len >= self._min_buffer_to_start:
                        self._tts_playback_started = True
                        should_play_tts = True

                if should_play_tts and buffer_len >= chunk_size:
                    tts_chunk = bytes(self._tts_output_buffer[:chunk_size])
                    del self._tts_output_buffer[:chunk_size]

                    ambient = np.frombuffer(ambient_bytes, dtype=np.int16).astype(np.float32) / 32768.0
                    tts = np.frombuffer(tts_chunk, dtype=np.int16).astype(np.float32) / 32768.0
                    mixed = np.clip(ambient + tts, -0.95, 0.95)
                    output_bytes = (mixed * 32767).astype(np.int16).tobytes()

                elif should_play_tts and buffer_len > 0:
                    tts_chunk = bytes(self._tts_output_buffer[:])
                    self._tts_output_buffer.clear()
                    self._tts_playback_started = False

                    ambient = np.frombuffer(ambient_bytes, dtype=np.int16).astype(np.float32) / 32768.0
                    tts_samples = len(tts_chunk) // 2
                    tts = np.frombuffer(tts_chunk, dtype=np.int16).astype(np.float32) / 32768.0
                    ambient[:tts_samples] += tts
                    mixed = np.clip(ambient, -0.95, 0.95)
                    output_bytes = (mixed * 32767).astype(np.int16).tobytes()

                else:
                    output_bytes = ambient_bytes

            await self._send_audio_to_client(output_bytes)

        except Exception:
            logger.exception("[VoiceLive] Error in _send_continuous_audio")

    # ------------------------------------------------------------------
    # Cleanup
    # ------------------------------------------------------------------

    async def cleanup(self):
        """Cancel background tasks and close the Voice Live connection."""
        if self._receiver_task:
            self._receiver_task.cancel()
            try:
                await self._receiver_task
            except (asyncio.CancelledError, Exception):
                pass
            self._receiver_task = None
        if self._conn_ctx:
            try:
                await self._conn_ctx.__aexit__(None, None, None)
            except Exception:
                pass
            self._conn_ctx = None
            self.conn = None
        if self._credential:
            try:
                await self._credential.close()
            except Exception:
                pass
            self._credential = None
        if self.fabric_tools:
            try:
                await self.fabric_tools.close()
            except Exception:
                pass
            self.fabric_tools = None
        logger.info("[VoiceLive] Cleaned up")
