# Changelog

## 0.1.0 (2026-03-11)

Initial release.

- `AaaspEx.Executor` behaviour + dispatcher with configurable backends
- `AaaspEx.Executor.JidoDirect` — single-turn LLM execution via ReqLLM
- `AaaspEx.Executor.JidoReAct` — ReAct (Reason + Act) tool-calling loop
- `AaaspEx.Tools.Registry` — extensible tool name → `Jido.Action` mapping
- `AaaspEx.Tools.Actions.{SearchWeb,ReadUrl,HttpRequest}` — built-in tools
- `AaaspEx.RunContext` + `AaaspEx.AgentDef` — lightweight, Ecto-free structs
