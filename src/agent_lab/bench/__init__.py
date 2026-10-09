"""``alab bench``: measure the running service through the gateway (T06, design section 10).

``runner`` checks that ``alab serve`` runs, creates a temporary API key and
runs the sections in ``suites``; ``client`` sends the requests and reads the
backend's per-request statistics; ``prompts`` builds prompts of a given token
length; ``report`` writes the JSON and Markdown reports to ``var/bench/``.
"""
