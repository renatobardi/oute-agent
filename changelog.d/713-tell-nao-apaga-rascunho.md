### Fixed
- **`oute-swarm tell` não apaga o rascunho da sessão** (#713). Antes, com texto no campo da sessão, o `tell` digitava por cima e mandava `ctrl+c`, apagando o que o Bardi escrevia, e registrava `ok`. Agora não digita nem limpa: sai com código 7, a mensagem não é entregue e a recusa vai ao log da rodada. **Precisa de release** (o `oute-swarm` vai na imagem).
