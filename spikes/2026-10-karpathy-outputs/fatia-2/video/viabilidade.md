# Vídeo explicativo sob medida: viabilidade (spike #458, fatia 2)

Data de acesso de todas as fontes: 2026-10-04. Só pesquisa: nada foi instalado nem rodado. Marcação "opinião" = julgamento meu, sem fonte. "não verificado" = não consegui confirmar.

## 1. Ferramentas de animação como código

| Ferramenta | Licença | Último release | Apple Silicon / Linux arm64 | Dependências pesadas |
|---|---|---|---|---|
| Manim Community | MIT | 0.21.0, 2026-08-10 | Pip puro (wheel `py3-none-any`); arm64 depende das rodas das dependências (numpy, scipy, pycairo, av, manimpango): não verificado em Linux arm64. Docs citam Apple Silicon e Linux | Cairo e Pango (no Linux, compila com C e headers; no macOS, Homebrew `cairo`, `pkg-config`); LaTeX opcional mas recomendado para fórmulas (MacTeX é grande); Python 3.11 ou mais; imagem Docker `manimcommunity/manim` existe |
| ManimGL (3b1b) | MIT | 1.7.2, 2024-12-13 (parado há cerca de 22 meses) | Não verificado | OpenGL, LaTeX, FFmpeg; Python 3.7 a 3.10 nos metadados (velho) |
| Remotion | Fonte aberta com licença própria: grátis para pessoa física, empresa com até 3 funcionários, ONG e avaliação; acima disso, licença paga de empresa (preço não verificado) | 4.0.532, 2026-10-01 (ativo) | Chrome Headless Shell tem build `mac-arm64` e `linux-arm64`; funciona nos dois | Node, Chromium próprio (baixado em `node_modules/.remotion`), FFmpeg embutido; Linux precisa de libs via `apt` (`libnss3`, `libgbm`, etc.); Alpine não suportado |
| Motion Canvas | (licença não verificada) | 3.17.2, 2024-12-14 (parado há cerca de 22 meses) | não verificado | Node, navegador para o editor; render por plugin |

Tamanho de instalação: não medido (nenhuma fonte achada). Opinião: Manim sem LaTeX é leve (dezenas de MB de Python); com MacTeX são GB; Remotion traz um Chromium (centenas de MB). Manim 0.21 trouxe renderização de texto por Typst (alternativa ao LaTeX, na versão mais nova) e Cairo 2.2x mais rápido em cenas pesadas.

Fontes:
- https://pypi.org/pypi/manim/json (licença, versão, datas, requires_dist)
- https://api.github.com/repos/ManimCommunity/manim/releases/latest (0.21.0, Typst, speedup)
- https://docs.manim.community/en/stable/installation/uv.html (LaTeX opcional, Cairo, Pango, MacTeX)
- https://docs.manim.community/en/stable/installation.html (Docker `manimcommunity/manim`)
- https://pypi.org/pypi/manimgl/json e https://api.github.com/repos/3b1b/manim/releases/latest
- https://api.github.com/repos/remotion-dev/remotion/releases/latest
- https://github.com/remotion-dev/remotion/blob/main/LICENSE.md
- https://www.remotion.dev/docs/miscellaneous/linux-dependencies e https://www.remotion.dev/docs/miscellaneous/chrome-headless-shell
- https://api.github.com/repos/motion-canvas/motion-canvas/releases/latest

## 2. Narração local e alternativa sem narração

| Opção | Licença | pt-BR | Observações |
|---|---|---|---|
| `say` do macOS | Embutido no sistema | Vozes pt-BR existem (Luciana, Felipe); qualidade não verificada | Zero instalação; vozes extras baixam em Ajustes. Opinião: robótica, mas inteligível |
| Piper (`piper-tts`) | GPL-3.0 (repo `piper1-gpl`); vozes no repo `rhasspy/piper-voices` marcadas MIT | 4 vozes pt_BR: cadu, edresson, faber, jeff | Último release v1.8.0, 2026-09-04; projeto procura mantenedores; `pip install`; pasta de vozes pt_BR com 253 MB no total (por voz não verificado); velocidade não verificada (opinião: roda em CPU, inclusive no servidor arm64) |
| Kokoro-82M | Apache 2.0 | 3 vozes pt-BR (`pf_dora`, `pm_alex`, `pm_santa`); notas de qualidade vão de F+ a A-, e a página avisa que idiomas além do inglês têm menos dados; nota exata do pt-BR não verificada | 82 milhões de parâmetros; pronúncia pt-BR por fallback `espeak-ng` |
| MLX-audio | MIT | Lista português entre os idiomas (Kokoro, Qwen3-TTS) | Só Apple Silicon (Python 3.10 ou mais, MLX); último release v0.5.7, 2026-09-28; roda os modelos acima no Mac |

Sem narração: legenda queimada no vídeo ou no HTML (texto na tela). Opinião: para relatório de agente, legenda basta e elimina o problema de sincronia e de pronúncia de nomes técnicos (`oute-sonar`, siglas).

Fontes:
- https://huggingface.co/hexgrad/Kokoro-82M e https://huggingface.co/hexgrad/Kokoro-82M/blob/main/VOICES.md
- https://huggingface.co/rhasspy/piper-voices/tree/main/pt/pt_BR
- https://github.com/OHF-Voice/piper1-gpl e https://api.github.com/repos/OHF-Voice/piper1-gpl/releases/latest
- https://github.com/Blaizzy/mlx-audio e https://api.github.com/repos/Blaizzy/mlx-audio/releases/latest
- https://gist.github.com/alvations/452477784dd763a18bb9666fcfdca402 (lista de vozes do `say`, só os nomes Luciana e Felipe, via busca)

## 3. Esforço por vídeo

Etapas (opinião, desenho típico): 1) roteiro em cenas, com a fala de cada cena ligada a um trecho da fonte; 2) um arquivo de cena por bloco (Manim: uma classe `Scene` por bloco; Remotion: um componente React por bloco); 3) render de cada cena; 4) áudio por cena (TTS) ou legenda; 5) montagem com `ffmpeg` (concatena e mistura). Ordem de grandeza (opinião, não medido): 100 a 300 linhas de Python/TSX para 1 a 3 min, mais um script de montagem de 20 a 40 linhas; o ciclo "render, olhar, corrigir" repete 2 a 5 vezes.

Tempo de render por minuto de vídeo: não medido; as buscas não achei benchmark (Manim: só a nota de 2.2x mais rápido no Cairo em 0.21; Remotion: usa metade dos threads por padrão e tem `npx remotion benchmark`). Opinião: em CPU de servidor sem GPU, minutos de render por minuto de vídeo.

Onde o agente erra (fonte): benchmark ManiBench aponta alucinação de API do Manim (versão errada), deriva visual (animação que diverge da lógica, ordem de eventos errada). Sistema ManimAgent relata sobreposição de texto e corte fora da tela, e que um laço com modelo de visão olhando os quadros baixou erros de execução e layout de 65% para menos de 8% (alegação do projeto, não verificada de forma independente). Sincronia entre fala e cena: opinião, é o ponto mais frágil, porque a duração da voz só se sabe depois do TTS.

Fidelidade (o vídeo diz o que a fonte diz?): não achei método padrão. Code2Video avalia com VLM como juiz e com o TeachQuiz (um modelo responde perguntas depois de "assistir"); não relata custo. Opinião para o nosso caso: (a) o roteiro é gerado como lista de afirmações, cada uma com citação do trecho do relatório; (b) um segundo passo, mecânico, confere que cada número e nome do vídeo aparece na fonte (`grep`); (c) o Bardi assiste a um vídeo de 1 a 3 min, mas conferir é mais lento que ler o texto.

Fontes:
- https://arxiv.org/html/2603.13251v1 (ManiBench)
- https://arxiv.org/abs/2510.01174 (Code2Video; sem dados de custo)
- https://manifund.org/projects/manimagent-an-open-25000-k12-video-library- (ManimAgent, 65% para menos de 8%)
- https://www.remotion.dev/docs/performance (concorrência)

## 4. Custo

Tokens de saída por vídeo: não medido (nenhuma fonte achada; Code2Video não publica). Opinião: milhares a poucas dezenas de milhares de tokens de saída por vídeo, mais as repetições do laço de correção.

APIs pagas de narração (só nomes e preço público; nenhuma será usada):
- ElevenLabs: grátis 10 mil créditos por mês (cerca de 10 min); Starter US$ 6; Creator US$ 11; Pro US$ 99 (fonte de terceiro, https://www.happyrobot.ai/hub/elevenlabs-pricing; o preço oficial não foi conferido).
- OpenAI TTS: `tts-1` US$ 15 por 1 milhão de caracteres; `tts-1-hd` US$ 30; `gpt-4o-mini-tts` US$ 0,60 por 1 milhão de tokens de entrada e US$ 12 por 1 milhão de tokens de áudio de saída (terceiro, https://www.s-anand.net/blog/openai-tts-cost/ e https://llm-stats.com/models/tts-1).
- Google Cloud TTS: Standard e WaveNet a partir de US$ 4 por 1 milhão de caracteres; Chirp 3 HD US$ 30; Studio US$ 160 (https://cloud.google.com/text-to-speech/pricing, via busca; valores lidos em resumo, não na página).

## 5. Alternativas mais baratas (opinião, sem fonte)

- Página HTML com animação CSS/SVG: o agente já escreve HTML; zero render, zero instalação, abre em qualquer navegador; passos com botão "próximo"; diff de texto fica copiável e conferível. Ganho de "ver a sequência" fica quase todo.
- GIF ou asciinema: serve só para fluxo de terminal (o que o agente rodou); sem narração; asciinema grava texto, é leve e copiável.
- Diagrama estático (SVG ou Mermaid) com legenda: cobre "como as partes se ligam".
- Já existe no repo o caminho de publicar página como artefato (ferramenta Artifact do Claude Code); reaproveitável. Não verificado se o fluxo do repo o usa para relatórios.

## 6. Veredito

1. Viável com ressalvas, mas não vale agora como saída padrão: o ganho sobre uma página HTML animada é pequeno e o custo (render, TTS, conferência) é bem maior.
2. Tecnicamente cabe: Manim (MIT, ativo, sem LaTeX se não houver fórmula) ou Remotion (Chromium arm64 existe; licença limita empresa acima de 3 pessoas) e Kokoro/MLX-audio no Mac; render no Mac, não no container.
3. Riscos fortes: layout, sincronia fala-cena e fidelidade; pt-BR local é o ponto fraco (Kokoro tem 3 vozes com dados escassos; qualidade medida não verificada).
4. Rota barata para vídeo: sem narração, legenda queimada, Manim em Docker oficial ou no Mac, 1 minuto.
5. Menor teste real (não rodar agora): pegar o relatório de um PR já auditado, pedir ao agente roteiro de 5 cenas com citações, renderizar 60 s com legenda, medir tokens, minutos de render e correções; comparar com uma página HTML animada do mesmo conteúdo; o Bardi diz qual entendeu mais rápido.
