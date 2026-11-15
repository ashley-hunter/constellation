# Constellation runs its own MCP server in every session

Claude Code has no event for "the agent needs a secret", and neither provider reports whether a task succeeded. So Constellation hosts its own MCP server and attaches it to every Session it launches, offering `request_secret` and `report_outcome`. This gives both providers one mechanism for Secret asks and outcomes, and keeps secrets out of transcripts. We rejected provider-native features: Codex's `isSecret` questions have no Claude equivalent, and structured output reshapes the agent's final message.
