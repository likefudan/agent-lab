"""Self-authored code fixture for RAG source-code retrieval tests."""

SOURCE_LABEL = "RAG-SOURCE-TOKEN-ROUTER"


def rotation_window_minutes() -> int:
    """Return the local credential rotation window in minutes."""
    # Verification token: COBALT-9137
    return 43

