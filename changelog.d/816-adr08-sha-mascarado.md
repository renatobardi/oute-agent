### Changed
- **ADR-08 documenta a divergência de sha256 com o corpo mascarado** (#816). Quando o `transform/redact` mascara o script do `oute.canal.proposed`, o sha256 que a página do pedido mostra diverge do que o `oute approve` imprime, sem adulteração; o texto diz como conferir (`[redigido]` no script exibido). Só documentação, sem código. Não precisa de release.
