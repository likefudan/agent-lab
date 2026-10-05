"""The mlx-lm inference backend (design sections 3.3 and 6.1).

``settings`` turns a profile into the ``mlx_lm.server`` command line,
``launch`` is the process that sets the memory guard and runs the server, and
``process`` starts, stops and inspects that process for ``alab serve``,
``alab stop`` and ``alab status``.
"""
