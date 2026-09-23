from voclaude.csm_engine import SentenceChunker


def stream(text, step=7):
    chunker = SentenceChunker()
    out = []
    for i in range(0, len(text), step):
        out += chunker.feed(text[i:i + step])
    return out + chunker.flush()


def test_skips_code_and_markdown():
    text = (
        "Sure! I looked at **session_manager.py** and found the bug.\n\n"
        "```python\ndef foo():\n    return 1.\n```\n"
        "- First, run `npm test`. It passes.\n"
        "- See [the docs](https://x.y/z) for more. Version 3.5 works fine!"
    )
    spoken = " ".join(stream(text))
    assert "def foo" not in spoken and "```" not in spoken
    assert "session manager.py" in spoken
    assert "the docs" in spoken and "https" not in spoken
    assert "Version 3.5 works fine!" in spoken
