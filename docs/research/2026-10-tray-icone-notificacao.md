# Ícone genérico na notificação do OuteTray (macOS 26.5.2)

**Estado:** pesquisa da fase `strat` (#563, PR #571). Data: 2026-10-05. Nenhum teste rodou no Mac nesta pesquisa.
**Decisão do Bardi:** escolher qual teste da seção 2 roda primeiro e se alguma correção da seção 3 vira trabalho.
**Local do arquivo:** o repo não tem convenção de pasta para pesquisa (`ls docs` mostra só `adr`, `agents`, `epics`). Este arquivo usa `docs/research/`.

Como ler: "a fonte afirma" é o que o link diz. "Inferência do autor" é conclusão desta pesquisa, sem fonte direta. "Fato medido" é medição feita no Mac na sessão do #563 e passada no pedido desta pesquisa; esta pesquisa não repetiu a medição.

## 1. Resposta curta

1. **Causa mais provável: a Central de Notificações guarda o ícone por identificador do app.** Ela salvou o ícone genérico quando o `pro.oute.tray` mandou a primeira notificação, ainda sem ícone. Grau de certeza: médio (inferência do autor, apoiada em quatro relatos independentes; nenhuma fonte da Apple descreve esse cache no macOS).
2. **O macOS 26.4 ou posterior mudou algo nesse caminho.** No 26.2, `killall NotificationCenter` resolveu um caso igual ao nosso ([AgentUsage PR #2](https://github.com/vlondon/AgentUsage/pull/2)). No 26.4, o mesmo comando não trocou o ícone guardado ([swiftDialog #633](https://github.com/swiftDialog/swiftDialog/issues/633)). O nosso Mac roda o 26.5.2 e o comando também não teve efeito (fato medido).
3. **Não achei fonte que explique o cache nem como limpar no 26.4+.** O que as fontes sustentam como saída: reiniciar o Mac ([JUCE](https://forum.juce.com/t/macos-local-push-notification-app-icon-not-shown-in-notification/62691), [Keyboard Maestro](https://forum.keyboardmaestro.com/t/notifications-in-macos-monterey-show-incompatible-app-icon/24364), e um engenheiro da Apple, no iOS, em [thread 775787](https://developer.apple.com/forums/thread/775787)).
4. **Primeiro teste (recomendação do autor):** instalar uma cópia do app com outro identificador (teste T2). Ele não interrompe a sessão do Mac e separa "cache por identificador" de "defeito no pacote".

## 2. Hipóteses, da mais para a menos provável

### H1. Ícone guardado por identificador, salvo antes de o app ter ícone

**A favor**
- Caso quase igual ao nosso: app SwiftPM, `LSUIElement`, montado por script, assinatura ad-hoc (`codesign --force --deep --sign -`), macOS 26.2. O autor afirma: "The blank icon came from Notification Center's display process, which kept the icon it saved when the app first sent notifications, before the app had an icon. Restarting `usernoted` didn't clear it; restarting that process (`killall NotificationCenter`) did." Fonte: [AgentUsage PR #2](https://github.com/vlondon/AgentUsage/pull/2).
- JUCE, macOS 14.6.1: o ícone certo aparece no Dock e o genérico na notificação. Um membro da equipe JUCE afirma que o ícone aparece certo "only after restarting the computer". O autor do relato confirma. Fonte: [fórum JUCE](https://forum.juce.com/t/macos-local-push-notification-app-icon-not-shown-in-notification/62691).
- Keyboard Maestro, macOS 12: o autor do app viu ícone errado na notificação e afirma "I restarted, and it went back to normal". Fonte: [fórum Keyboard Maestro](https://forum.keyboardmaestro.com/t/notifications-in-macos-monterey-show-incompatible-app-icon/24364).
- swiftDialog, macOS 26.4: a notificação mostrou o ícone da versão 2.x, que não estava mais instalada, mesmo depois de `killall NotificationCenter`. O mantenedor afirma que isso aponta para "a system notification cache issue on that device". Fonte: [swiftDialog #633](https://github.com/swiftDialog/swiftDialog/issues/633#issuecomment-4114296795).
- Um colaborador do swiftDialog afirma: "the system caches the previously used app icon if you already sent notifications". Fonte: [swiftDialog #640](https://github.com/swiftDialog/swiftDialog/issues/640#issuecomment-4129304355).
- iOS (outra plataforma): um engenheiro da Apple afirma que o ícone da notificação não mudar logo depois de uma atualização "is known, and is under investigation" e que a Apple espera o ícone certo "after a restart". Fonte: [thread 775787](https://developer.apple.com/forums/thread/775787).
- Fato medido: o app pediu autorização de notificação dias antes de ter ícone. O `NSWorkspace.shared.icon(forFile:)` já desenha a sakura; só a notificação segue genérica.

**Contra**
- Fato medido: `killall` de `NotificationCenter` e de `usernoted` rodou 2 vezes sem efeito. No 26.2 esse comando bastou (AgentUsage). Isso só é coerente com H1 se o cache do 26.4+ fica fora desses dois processos (inferência do autor; o swiftDialog #633 mostra o mesmo sintoma no 26.4).
- Fato medido: `defaults read com.apple.ncprefs apps` não tem `pro.oute.tray`. Não achei fonte que diga onde o macOS 26 guarda esse registro. Não verificado.

**Testes** (seção "Testes" abaixo): T1, T2, T3, T4.

### H2. Mudança do macOS 26.4+ em como a Central de Notificações obtém o ícone

**A favor**
- A documentação do swiftDialog afirma: "From macOS 26.4 onward, setting the Dialog.app bundle icon in order to set the notification icon may not operate as expected." Fonte: [notas do swiftDialog 3.1.0](https://swiftdialog.app/reference/releasenotes/sd3-1-0/).
- O mantenedor do swiftDialog suspeita de mudança contra falsificação de ícone ("spoofing") no 26.4. Ele não confirma. Fonte: [swiftDialog #633](https://github.com/swiftDialog/swiftDialog/issues/633#issuecomment-4133705625).
- Jamf Self Service, macOS 26.5.1: o ícone personalizado aparece no Dock e não aparece na notificação. Um usuário afirma: "It seems like a regression since macOS 26". Fonte: [comunidade Jamf](https://community.jamf.com/general-discussions-2/custom-self-service-branding-no-longer-applies-to-icon-in-notifications-58458) (fonte secundária).
- Um usuário relata que no macOS 15.7.4 o mesmo fluxo funciona. Fonte: [swiftDialog #633](https://github.com/swiftDialog/swiftDialog/issues/633#issuecomment-4133090087).

**Contra**
- Nesses relatos o ícone trocado é um ícone personalizado, posto sobre o app depois da instalação. A notificação mostra o ícone original do pacote, não o genérico. No nosso caso o ícone é o do próprio pacote e está coberto pela assinatura (fato medido: `codesign --verify --deep` válido). Então H2 sozinha não explica o genérico (inferência do autor).
- Num Mac limpo com 26.4, o swiftDialog mostrou o ícone original do pacote dele. Fonte: [swiftDialog #633](https://github.com/swiftDialog/swiftDialog/issues/633#issuecomment-4133394772). O swiftDialog tem assinatura de desenvolvedor; o nosso app é ad-hoc. O efeito dessa diferença: não verificado.
- As notas de versão da Apple para o 26.4 não foram localizadas nesta pesquisa. Não verificado.

**Testes:** T2 (se a cópia com identificador novo também sair genérica, H1 cai e H2/H3/H4 sobem), T6.

### H3. Assinatura ad-hoc: o macOS não acompanha a identidade do app entre instalações

**A favor**
- A Apple afirma: "Ad hoc signed code [...] has a DR but it's tied to that specific version of the code. In both cases macOS can't reliably track the identity of the code." Fonte: [TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).
- O `oute tray install` apaga o app e assina de novo a cada instalação (`scripts/oute:1071@85ed7dc` e `scripts/oute:1099@85ed7dc`). Cada instalação gera um cdhash novo (fato medido).
- Fato medido: o `ncprefs` não tem entrada do app. Um registro preso a um cdhash antigo explicaria isso (inferência do autor, sem fonte).

**Contra**
- O AgentUsage também assina ad-hoc e mostrou o ícone certo no 26.2. Fonte: [AgentUsage PR #2](https://github.com/vlondon/AgentUsage/pull/2).
- O TN3127 fala de recursos protegidos por privacidade (ex.: microfone). Ele não fala de ícone de notificação. A ligação com o ícone é inferência do autor.
- Fato medido: as notificações chegam como banner. A autorização, portanto, não se perdeu.

**Testes:** T6.

### H4. Formato do ícone: o macOS 26 esperaria `Assets.car` ou `.icon` do Icon Composer

**A favor**
- A Apple descreve o arquivo do Icon Composer como a fonte do ícone "everywhere your app icon appears" no macOS 26. Fonte: [Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer).
- O macOS 26 põe ícone antigo dentro de uma placa cinza ("if an app icon is not already a squircle, macOS automatically draws it inside a gray squircle"). Fonte: [lapcatsoftware](https://lapcatsoftware.com/articles/2025/6/2.html) (fonte secundária).

**Contra**
- Fato medido: `Assets.car` (por `actool --app-icon AppIcon`) mais `CFBundleIconName` não mudou a notificação. Ressalva: o teste rodou com o possível cache de H1 ativo. O AgentUsage registra a mesma ressalva: "it isn't proven that `Assets.car` alone is necessary".
- A placa cinza mostra o desenho do app dentro dela. O que vemos é o ícone genérico, sem desenho (fato medido). Não achei relato de ícone `.icns` válido que saia genérico só na notificação.
- O CodexBar, app de barra de menu montado por script, usa só `CFBundleIconFile` com `.icns`. Fonte: [`Scripts/package_app.sh`](https://github.com/steipete/CodexBar/blob/main/Scripts/package_app.sh). Se a notificação dele mostra o ícone no 26.5: não verificado.
- O `Assets.car` gerado a partir de PNG contém só a imagem de vários tamanhos. O formato novo acrescenta um `iconstack` com as camadas. Fonte: [thread 794485](https://developer.apple.com/forums/thread/794485) (relato de usuário, sem resposta da Apple). O `.icon` não foi testado.

**Testes:** T7.

### H5. Forma de abrir o app: `LSUIElement`, `~/Applications`, LaunchAgent que chama o binário direto

**A favor**
- O LaunchAgent chama `Contents/MacOS/OuteTray` direto, sem passar pelo LaunchServices (`scripts/oute:1114@85ed7dc`). Efeito sobre o ícone da notificação: não verificado. Não achei fonte.

**Contra**
- AgentUsage e CodexBar são `LSUIElement` (fontes acima). O AgentUsage mostrou o ícone certo.
- Fato medido: o `lsregister -dump` mostra o ícone registrado e só um app com o identificador.
- O campo `isSystemManaged: true` do registro: não achei fonte que explique. Não verificado.

**Testes:** T8.

### Testes, do mais barato ao mais caro

Os comandos abaixo são propostas para o Mac. Nenhum rodou. Os que não têm fonte são recomendação do autor.

| # | Teste | Custo | O que confirma ou derruba |
|---|---|---|---|
| T1 | Só leitura. Rodar `log stream --predicate 'process == "NotificationCenter" OR process == "usernoted" OR process == "iconservicesagent"'` e mandar uma notificação. Ler a tabela `app` do banco `~/Library/Group Containers/group.com.apple.usernoted/db2/db` (caminho: [9to5Mac](https://9to5mac.com/2024/09/01/security-bite-apple-addresses-privacy-concerns-around-notification-center-database-in-macos-sequoia/), fonte secundária). | minutos; o banco pode exigir Acesso Total ao Disco (não verificado) | Mostra quem busca o ícone e se o identificador tem registro antigo. Não derruba hipótese sozinho. |
| T2 | Copiar o app para `~/Applications/OuteTrayTeste.app`, trocar `CFBundleIdentifier` para `pro.oute.tray.teste` (`plutil -replace`), assinar ad-hoc de novo, abrir com `open` e esperar uma notificação. O macOS pede a autorização de novo. | 10 min; dois trays abertos durante o teste | Sakura na notificação: H1 confirmada (cache por identificador). Genérico: H1 cai; o defeito está no pacote, na assinatura ou no formato (H2 a H5). |
| T3 | Encerrar a sessão do usuário e entrar de novo. | fecha os apps abertos | Sakura: H1 confirmada; o cache vive na sessão. |
| T4 | Reiniciar o Mac. | interrompe tudo | Sakura: H1 confirmada (como JUCE e Keyboard Maestro). Genérico depois do reinício: H1 enfraquece muito. |
| T5 | Limpar os caches do IconServices e reiniciar. Comandos de uso comum, sem documentação da Apple: `sudo rm -rf /Library/Caches/com.apple.iconservices.store`, apagar `com.apple.iconservices*` em `$(getconf DARWIN_USER_CACHE_DIR)`, `killall Dock Finder iconservicesagent`. Fonte: [thread 676723](https://developer.apple.com/forums/thread/676723) (respostas de usuários). `CUIDADO: o rm apaga o cache de ícones do sistema. O macOS refaz o cache; os ícones podem demorar a voltar.` | sudo + reinício | Separa cache do IconServices de cache da Central de Notificações. Fato medido contra: o `NSWorkspace` já desenha a sakura, então o IconServices parece em dia. |
| T6 | Assinar com identidade estável (certificado autoassinado de assinatura de código no chaveiro) em vez de `-`, com identificador novo para não herdar cache. | criar o certificado uma vez | Sakura só com identidade estável: H3 confirmada. |
| T7 | Gerar um `.icon` no Icon Composer e compilar com `actool` (comando na seção 3, item C). | exige desenhar o `.icon` | Sakura só com `.icon`: H4 confirmada. |
| T8 | Instalar em `/Applications` e abrir com `open -a` em vez do LaunchAgent. | baixo, mas muda duas coisas de uma vez | Sakura: H5 confirmada; repetir separando as duas mudanças. |

Ordem recomendada (recomendação do autor): T1, T2, T3, T4. Só depois T6, T7, T8. O T5 fica por último: tem mais risco e a evidência é contra.

## 3. Correções possíveis no `oute tray install`

| # | Correção | Custo | Risco | Depende de |
|---|---|---|---|---|
| A | Manter o anexo com a sakura à direita (já está em `tray/Sources/OuteTray/Notifications.swift:25@85ed7dc`). O Tauri descreve a mesma saída: "add a second icon on the right side of the notification" ([discussão 7686](https://github.com/orgs/tauri-apps/discussions/7686)). | zero | nenhum; o ícone da esquerda segue genérico | nada |
| B | Documentar: depois da primeira instalação com ícone, reiniciar o Mac (ou encerrar a sessão). O AgentUsage documenta `killall NotificationCenter` no README ([PR #2](https://github.com/vlondon/AgentUsage/pull/2)); no nosso 26.5.2 esse comando não bastou (fato medido). | uma linha de texto | nenhum | T3 ou T4 confirmar |
| C | Gerar `Assets.car` com `actool` quando o Xcode existe e gravar `CFBundleIconName`, mantendo `CFBundleIconFile` para macOS antigo. Modelo pronto: [`scripts/package_app.sh` do AgentUsage](https://github.com/vlondon/AgentUsage/pull/2). Para o `.icon`: `actool AppIcon.icon --compile <saída> --app-icon AppIcon --include-all-app-icons --target-device mac --platform macosx --minimum-deployment-target 26.0 --output-partial-info-plist <arquivo>` ([Hendrik Erz](https://www.hendrik-erz.de/post/supporting-liquid-glass-icons-in-apps-without-xcode), fonte secundária). | médio; o `.icon` precisa ser desenhado e versionado | o `actool` exige Xcode completo (mesma fonte); as opções para manter ícone separado por versão mudaram no Xcode 26.1 ([mjtsai](https://mjtsai.com/blog/2025/08/08/separate-icons-for-macos-tahoe-vs-earlier/), fonte secundária) | T7 confirmar; hoje a evidência é contra |
| D | Trocar o identificador do app uma vez (ex.: `pro.oute.tray2`). O macOS trata como app novo, sem ícone guardado. | baixo; o `TRAY_LABEL` também nomeia o LaunchAgent, então a troca pede migração do plist antigo | o macOS pede a autorização de notificação de novo; o registro antigo fica órfão | T2 confirmar |
| E | Assinar com identidade estável em vez de ad-hoc. A Apple afirma que código ad-hoc tem identidade presa à versão ([TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)). | médio; criar e guardar um certificado no chaveiro do Mac; o script passa a depender dele | certificado ausente quebra a instalação; precisa de reserva para ad-hoc | T6 confirmar |
| F | Não apagar o app a cada instalação: trocar só o binário e assinar de novo. | baixo | não muda o cdhash novo a cada instalação; efeito sobre o ícone: não verificado | nada |
| G | Notificação desenhada pelo próprio app (janela própria), como o swiftDialog 3.1 fez com "pseudo notifications" ([notas 3.1.0](https://swiftdialog.app/reference/releasenotes/sd3-1-0/)). | alto | a notificação não fica na Central de Notificações ("do not persist once dismissed", mesma fonte) | só se nada acima resolver |

Recomendação do autor: manter A, rodar T2 e T4, e decidir entre B e D pelo resultado. C e E só entram se T7 ou T6 confirmarem.

## 4. O que não foi possível verificar

- **Quem desenha o ícone e de onde ele lê.** Não achei documentação da Apple sobre o caminho do ícone na notificação do macOS (usernoted, NotificationCenter, IconServices). As páginas [CFBundleIconName](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleiconname) e [CFBundleIconFile](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleiconfile) só definem as chaves. A afirmação "o sistema usa sempre o ícone do app" vem de projetos abertos ([swiftDialog #640](https://github.com/swiftDialog/swiftDialog/issues/640#issuecomment-4129304355), [Tauri](https://github.com/orgs/tauri-apps/discussions/7686)).
- **Onde o cache fica e quando o macOS relê.** Nenhuma fonte diz o arquivo ou o processo. Não verificado.
- **O que mudou no 26.4.** Só há o aviso do swiftDialog e a suspeita do mantenedor. Notas de versão da Apple: não localizadas.
- **Resposta de engenheiro da Apple sobre macOS.** A única resposta de engenheiro da Apple achada trata do iOS ([thread 775787](https://developer.apple.com/forums/thread/775787)). Não achei resposta do Quinn sobre ícone de notificação.
- **`ncprefs` sem entrada no macOS 26** e **`isSystemManaged: true`**: sem fonte.
- **Efeito de `LSUIElement`, de `~/Applications` e do LaunchAgent sobre o ícone**: sem fonte.
- **`CFBundleIcons`/`CFBundlePrimaryIcon` no macOS** e **`_identityImage` do `NSUserNotification`**: não pesquisados a fundo; sem fonte primária.
- **terminal-notifier, SwiftBar, xbar, Stats, Maccy, MeetingBar, Hammerspoon, Rectangle**: não li os scripts de empacotamento deles. O `alerter` troca o ícone pela opção `--sender` (usa o identificador de outro app) e `--app-icon` ([README](https://github.com/vjeantet/alerter#readme)); isso não serve a um app com identificador próprio.
- **Página de Notificações das HIG da Apple**: o conteúdo não carregou na leitura automática. Não verificado.

## 5. Fontes

Acesso em 2026-10-05.

**Primárias (Apple)**
- [TN3127: Inside Code Signing: Requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)
- [Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)
- [CFBundleIconName](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleiconname), [CFBundleIconFile](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleiconfile)
- [Apple Developer Forums, thread 775787](https://developer.apple.com/forums/thread/775787) (resposta de engenheiro da Apple, iOS)
- [Apple Developer Forums, thread 780074](https://developer.apple.com/forums/thread/780074) (iOS 18.1+: reinício atualiza o ícone; relato de usuário)

**Primárias (código e issues de projetos abertos)**
- [vlondon/AgentUsage PR #2](https://github.com/vlondon/AgentUsage/pull/2): caso mais próximo do nosso
- [swiftDialog #633](https://github.com/swiftDialog/swiftDialog/issues/633), [swiftDialog #640](https://github.com/swiftDialog/swiftDialog/issues/640), [notas do swiftDialog 3.1.0](https://swiftdialog.app/reference/releasenotes/sd3-1-0/)
- [fórum JUCE: App Icon not shown in notification](https://forum.juce.com/t/macos-local-push-notification-app-icon-not-shown-in-notification/62691) (resposta da equipe JUCE)
- [fórum Keyboard Maestro](https://forum.keyboardmaestro.com/t/notifications-in-macos-monterey-show-incompatible-app-icon/24364) (resposta do autor do app)
- [Tauri, discussão 7686](https://github.com/orgs/tauri-apps/discussions/7686)
- [steipete/CodexBar `Scripts/package_app.sh`](https://github.com/steipete/CodexBar/blob/main/Scripts/package_app.sh)
- [IBM mac-ibm-notifications: Known Issues](https://github.com/IBM/mac-ibm-notifications/wiki/Known-Issues-And-Fixes) (`killall NotificationCenter` para ícone errado)
- [vjeantet/alerter README](https://github.com/vjeantet/alerter#readme)

**Secundárias (pista)**
- [comunidade Jamf: ícone de marca some da notificação no macOS 26](https://community.jamf.com/general-discussions-2/custom-self-service-branding-no-longer-applies-to-icon-in-notifications-58458)
- [Apple Developer Forums, thread 676723](https://developer.apple.com/forums/thread/676723) e [thread 794485](https://developer.apple.com/forums/thread/794485) (só usuários, sem resposta da Apple)
- [Hendrik Erz: Liquid Glass icons sem Xcode](https://www.hendrik-erz.de/post/supporting-liquid-glass-icons-in-apps-without-xcode)
- [Michael Tsai: Separate Icons for macOS Tahoe vs. Earlier](https://mjtsai.com/blog/2025/08/08/separate-icons-for-macos-tahoe-vs-earlier/)
- [lapcatsoftware: macOS Tahoe forces all app icons into iOS squircles](https://lapcatsoftware.com/articles/2025/6/2.html)
- [9to5Mac: banco da Central de Notificações no macOS Sequoia](https://9to5mac.com/2024/09/01/security-bite-apple-addresses-privacy-concerns-around-notification-center-database-in-macos-sequoia/)

**Código deste repo** (branch `feat/563-tray-sakura`, `85ed7dc`)
- `scripts/oute:1061@85ed7dc` (`tray_install`), `tray/Sources/OuteTray/Notifications.swift:17@85ed7dc`

## Resultado dos testes no Mac (2026-10-05)

A hipótese H1 está confirmada: a Central de Notificações guarda o ícone por identificador.

- **Teste T2, com `.icns` e `Assets.car`:** uma cópia do app com o identificador `pro.oute.tray.teste` mostrou a sakura na pergunta de permissão do macOS. Fonte: pedido `20261005-193146-tray-563-teste-abre-uma-c-pia-do-outetra` e [screenshot](https://github.com/renatobardi/oute-agent/pull/571#issuecomment-6001606924).
- **Teste T2, só com `.icns`:** uma segunda cópia, `pro.oute.tray.teste2`, sem o `Assets.car` e sem `CFBundleIconName`, também mostrou a sakura. Fonte: pedido `20261005-193331-tray-563-apaga-a-c-pia-de-teste-e-abre-u` e os comentários do Bardi no PR #571.
- **Conclusão:** o `.icns` basta. O formato do ícone (H4) e a assinatura ad-hoc (H3) não são a causa. A correção é trocar o identificador do app no `oute tray install`.
- **Não verificado:** onde o macOS 26.5 guarda esse ícone e se um reinício do Mac o limpa para o `pro.oute.tray`.

