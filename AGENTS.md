<!-- LOVABLE:BEGIN -->
> [!IMPORTANT]
> This project is connected to [Lovable](https://lovable.dev). Avoid rewriting
> published git history — force pushing, or rebasing/amending/squashing commits
> that are already pushed — as it rewrites history on Lovable's side and the
> user will likely lose their project history.
>
> Commits you push to the connected branch sync back to Lovable and show up in
> the editor, so keep the branch in a working state.
<!-- LOVABLE:END -->

- As estatísticas do painel MQL5 são recalculadas pelo histórico de posições fechadas para permanecerem consistentes com o Testador de Estratégia.
- MQL5 diagnostics are opt-in configurable CSV observers of the existing strategy; capture trade events through a timer-drained queue so history selection and file writes do not slow the transaction callback.
- Preserve versioned MQL5 source deliveries and validate with portable source checks; native compilation and execution must be verified in MetaEditor/MetaTrader, which are unavailable in this sandbox.
