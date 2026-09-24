import asyncio
import logging
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

sys.path.insert(0, str(Path(__file__).parents[1]))

from app.config_validator import validate_config
from app.handler.voicelive_media_handler import VoiceLiveMediaHandler


class FakeConnection:
    def __init__(self):
        self.session = SimpleNamespace(update=AsyncMock())
        self.response = SimpleNamespace(create=AsyncMock())
        self.conversation = SimpleNamespace(
            item=SimpleNamespace(create=AsyncMock())
        )

    def __aiter__(self):
        async def events():
            if False:
                yield None

        return events()


class FakeConnectionContext:
    def __init__(self, connection=None, error=None):
        self.connection = connection or FakeConnection()
        self.error = error

    async def __aenter__(self):
        if self.error:
            raise self.error
        return self.connection

    async def __aexit__(self, *_args):
        return None


def make_config(enabled):
    return {
        "AZURE_VOICE_LIVE_ENDPOINT": "https://example.services.ai.azure.com",
        "VOICE_LIVE_MODEL": "gpt-realtime",
        "VOICE_LIVE_VOICE": "fr-FR-DeniseNeural",
        "AZURE_VOICE_LIVE_API_KEY": "test-key",
        "AZURE_USER_ASSIGNED_IDENTITY_CLIENT_ID": "",
        "ENABLE_FOUNDRY_IQ": str(enabled).lower(),
        "AZURE_AI_FOUNDRY_PROJECT_NAME": "project-test",
        "AZURE_AI_FOUNDRY_AGENT_ID": "call-center-knowledge-agent",
        "AMBIENT_PRESET": "none",
    }


class FoundryIqConfigurationTests(unittest.TestCase):
    def test_enabled_configuration_requires_agent_and_project(self):
        config = make_config(True)
        config["AZURE_AI_FOUNDRY_PROJECT_NAME"] = ""
        config["AZURE_AI_FOUNDRY_AGENT_ID"] = ""

        with patch("app.config_validator.sys.exit", side_effect=SystemExit), self.assertLogs(
            "app.config_validator", logging.ERROR
        ) as logs:
            with self.assertRaises(SystemExit):
                validate_config(config, None)

        output = "\n".join(logs.output)
        self.assertIn("AZURE_AI_FOUNDRY_PROJECT_NAME", output)
        self.assertIn("AZURE_AI_FOUNDRY_AGENT_ID", output)

    def test_disabled_configuration_keeps_direct_model_path(self):
        handler = VoiceLiveMediaHandler(make_config(False))
        captured = {}

        def connect(**kwargs):
            captured.update(kwargs)
            return FakeConnectionContext()

        with patch(
            "app.handler.voicelive_media_handler.voicelive_connect", connect
        ):
            asyncio.run(handler.connect_voicelive())

        self.assertEqual(captured["model"], "gpt-realtime")
        self.assertNotIn("agent_name", captured)

    def test_enabled_configuration_selects_foundry_agent(self):
        handler = VoiceLiveMediaHandler(make_config(True))
        captured = {}

        def connect(**kwargs):
            captured.update(kwargs)
            return FakeConnectionContext()

        with patch(
            "app.handler.voicelive_media_handler.voicelive_connect", connect
        ):
            asyncio.run(handler.connect_voicelive())

        self.assertEqual(captured["agent_name"], "call-center-knowledge-agent")
        self.assertEqual(captured["project_name"], "project-test")
        self.assertEqual(captured["api_version"], "2026-07-15")
        self.assertNotIn("model", captured)

    def test_default_session_uses_french_prompt_and_voice(self):
        handler = VoiceLiveMediaHandler(make_config(False))

        session = handler._session_config()

        self.assertIn("centre d'appels", session.instructions)
        self.assertIn("français", session.instructions)
        self.assertEqual(session.voice.name, "fr-FR-DeniseNeural")

    def test_agent_session_does_not_override_foundry_instructions(self):
        handler = VoiceLiveMediaHandler(make_config(True))

        session = handler._session_config()

        self.assertIsNone(session.instructions)
        self.assertEqual(session.voice.name, "fr-FR-DeniseNeural")

    def test_agent_connection_failure_is_reported(self):
        handler = VoiceLiveMediaHandler(make_config(True))

        with patch(
            "app.handler.voicelive_media_handler.voicelive_connect",
            return_value=FakeConnectionContext(error=RuntimeError("unavailable")),
        ), self.assertLogs(
            "telemetry.voicelive", logging.ERROR
        ) as logs:
            with self.assertRaises(RuntimeError):
                asyncio.run(handler.connect_voicelive())

        self.assertIn("agent_invocation status=failed", "\n".join(logs.output))

    def test_empty_retrieval_metadata_is_reported_without_content(self):
        handler = VoiceLiveMediaHandler(make_config(True))

        with self.assertLogs(
            "telemetry.voicelive", logging.INFO
        ) as logs:
            handler._log_tool_event(
                SimpleNamespace(result_count=0),
                "response.mcp_call.completed",
            )

        output = "\n".join(logs.output)
        self.assertIn("status=succeeded", output)
        self.assertIn("result_count=0", output)
        self.assertIn("empty=True", output)

    def test_successful_retrieval_metadata_is_reported(self):
        handler = VoiceLiveMediaHandler(make_config(True))

        with self.assertLogs(
            "telemetry.voicelive", logging.INFO
        ) as logs:
            handler._log_tool_event(
                SimpleNamespace(result_count=2),
                "response.mcp_call.completed",
            )

        output = "\n".join(logs.output)
        self.assertIn("status=succeeded", output)
        self.assertIn("result_count=2", output)
        self.assertIn("empty=False", output)

    def test_tool_failure_metadata_is_reported(self):
        handler = VoiceLiveMediaHandler(make_config(True))

        with self.assertLogs(
            "telemetry.voicelive", logging.INFO
        ) as logs:
            handler._log_tool_event(
                SimpleNamespace(error="tool unavailable"),
                "response.mcp_call.completed",
            )

        output = "\n".join(logs.output)
        self.assertIn("status=failed", output)
        self.assertNotIn("tool unavailable", output)

    def test_mcp_result_count_reads_only_result_metadata(self):
        output = '{"structuredContent":{"results":[{"content":"private"}]}}'

        self.assertEqual(VoiceLiveMediaHandler._mcp_result_count(output), 1)
        self.assertEqual(VoiceLiveMediaHandler._mcp_result_count(""), 0)

    def test_confirmed_ticket_function_returns_created_reference(self):
        handler = VoiceLiveMediaHandler(make_config(True))
        handler.authorized_customer_key = "CUST-001"
        handler.fabric_tools = SimpleNamespace(
            create_ticket=AsyncMock(
                return_value={"ticket_id": "TKT-2026-002852", "status": "Open"}
            )
        )
        handler.conn = FakeConnection()
        event = SimpleNamespace(
            name="create_support_ticket",
            call_id="call-1",
            arguments=(
                '{"customer_key":"CUST-001","subject":"Conveyor stopped",'
                '"description":"The conveyor stopped with fault E42.",'
                '"priority":"P2","user_confirmed":true,'
                '"conversation_id":"conversation-1","idempotency_key":"request-1"}'
            ),
        )

        asyncio.run(handler._handle_function_call(event))

        handler.fabric_tools.create_ticket.assert_awaited_once()
        output = handler.conn.conversation.item.create.await_args.kwargs["item"]
        self.assertIn("TKT-2026-002852", output["output"])

    def test_fabric_retrieval_injects_authenticated_customer(self):
        handler = VoiceLiveMediaHandler(make_config(True))
        handler.authorized_customer_key = "CUST-001"
        handler.fabric_tools = SimpleNamespace(
            retrieve=AsyncMock(
                return_value={"results": [], "result_count": 0, "message": "No match"}
            )
        )
        handler.conn = FakeConnection()
        event = SimpleNamespace(
            name="fabric_retrieve_business_data",
            call_id="call-1",
            arguments=(
                '{"intent":"ticket","customer_key":"CUST-001",'
                '"product_key":null,"ticket_id":"TKT-2026-1","query":null}'
            ),
        )

        asyncio.run(handler._handle_function_call(event))

        _, kwargs = handler.fabric_tools.retrieve.await_args
        self.assertEqual(kwargs["authorized_customer_key"], "CUST-001")
        self.assertEqual(kwargs["customer_key"], "CUST-001")

    def test_ticket_function_fails_closed_without_authenticated_customer(self):
        handler = VoiceLiveMediaHandler(make_config(True))
        handler.conn = FakeConnection()
        event = SimpleNamespace(
            name="create_support_ticket",
            call_id="call-1",
            arguments="{}",
        )

        asyncio.run(handler._handle_function_call(event))

        output = handler.conn.conversation.item.create.await_args.kwargs["item"]
        self.assertIn("unavailable", output["output"])


if __name__ == "__main__":
    unittest.main()
