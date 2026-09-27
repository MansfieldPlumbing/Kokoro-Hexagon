# AdaIN convolution runspace scheduling audit, 2026-09-27

A PowerShell `ForEach-Object -Parallel` prototype split one bounded
AdaIN convolution by output channel. Each worker retained the scalar
accumulation order and returned a private output segment; an analytic gate
was bit-identical to the serial operator. The mechanism was traced to
PowerShell `149ab5cd6cad34869177f86ef9a3da8414f85dc6`,
`src/System.Management.Automation/engine/InternalCommands.cs`
(`ForEachObjectCommand` and using-value admission) and
`src/System.Management.Automation/engine/hostifaces/PSTask.cs`
(`PSTaskPool`).

On this laptop, a 64-channel, 121-frame, 11-tap same-input comparison with
four runspace workers measured 5,848.8 ms serial and 19,386.2 ms parallel.
That is 0.30x serial throughput, not a speedup. The prototype was not
promoted into the reference or product path. This single fixture does not
rule out other parallel schedules or a PowerShell-authored emitted backend;
it does rule out claiming this channel-per-task implementation accelerates
the current correctness gate.

The attempted complete stock-layer phoneme-to-PCM scalar gate was stopped
after prolonged CPU activity without a stage result or output PCM. It is
not a failed numerical comparison and not a passed full-forward gate.
