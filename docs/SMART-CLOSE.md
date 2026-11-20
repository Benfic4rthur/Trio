# SmartClose: investigação de compatibilidade

Desde a versão 0.2.0 o vermelho do Trio fecha a janela pelo botão acessível. Ao confirmar o fechamento da última janela, o Trio pode pedir o encerramento do aplicativo. As exceções são configuradas no próprio Trio. O estudo abaixo documenta o comportamento das versões anteriores.


Data da inspeção: 14/11/2026. Nenhuma preferência, permissão ou processo do SmartClose foi alterado.

## Evidências locais observadas

- Aplicativo instalado: `/Applications/SmartClose.app`.
- Bundle ID: `com.smartclose.app`; versão **0.4.2**, build **10**.
- Processo estava ativo, PID **887**, durante a inspeção inicial (PID transitório).
- Executável universal arm64/x86_64, assinado Developer ID, hardened runtime, ticket de notarização anexado.
- SHA-256 do executável: `1cf4303cdda6b5b19b365145f25d830e562612b330e194e328e6773bad4fb2b5`.
- `nm -u` mostra importações de `CGEventTapCreate`, `CGEventTapEnable`, `CGEventGetLocation`, `AXUIElementCopyElementAtPosition`, `AXUIElementCopyAttributeValue`, `AXUIElementGetPid` e `CGWindowListCopyWindowInfo`.
- Strings incluem `EventMonitor`, `InterceptionController`, `swallowNextMouseUp`, `requestQuit` e mensagens de solicitação de encerramento.
- Preferências locais lidas: habilitado, modo `smartClose`, diagnóstico habilitado, tratamento de Cmd+W desabilitado. A lista de ignorados contém MIRA. Janelas minimizadas/ocultas não são contadas. A presença dessas preferências não prova, sozinha, que o event tap esteja saudável.

Os fatos de binário acima vieram de ferramentas shell (`plutil`, `file`, `nm`, `strings`, `codesign`, `shasum`), não de decompilação nem de Evidence REA. A skill REA foi consultada; nenhum servidor REA estava disponível na sessão. O diagnóstico CLI `rea-agents@6.9.0 doctor` não iniciou: Node local 24.21.0 está abaixo do mínimo 24.22.1 exigido. Nenhuma configuração nem runtime foi alterado; a investigação continuou com fonte oficial e ferramentas shell. Nenhum código foi injetado.

## Código oficial correspondente à versão

O repositório público do próprio projeto possui a tag [v0.4.2](https://github.com/mahirozdin/SmartClose/tree/v0.4.2), commit `322c0bafff52f9cdfa61356282bbd54003b96bb9`. Isso associa uma versão declarada, mas não é uma reprodução bit a bit do executável instalado.

- [EventMonitor.swift](https://github.com/mahirozdin/SmartClose/blob/v0.4.2/SmartCloseApp/Core/Interception/EventMonitor.swift): cria event tap em `.cghidEventTap`, posição `.headInsertEventTap`, opção `.defaultTap`. Observa `leftMouseDown`, `leftMouseUp` e `keyDown`. Quando o handler decide interceptar um mouseDown, descarta esse evento e o próximo mouseUp.
- [InterceptionController.swift](https://github.com/mahirozdin/SmartClose/blob/v0.4.2/SmartCloseApp/Core/Interception/InterceptionController.swift): no mouseDown, faz hit-test de Acessibilidade na coordenada do evento. Exige `AXButton` com subrole `AXCloseButton`, resolve janela/PID e avalia regras/quantidade de janelas. Sem ambiguidade e na última janela normal, pede encerramento. Não há filtro explícito rejeitando eventos sintéticos nesse caminho.
- [AXInspector.swift](https://github.com/mahirozdin/SmartClose/blob/v0.4.2/SmartCloseApp/Core/Accessibility/AXInspector.swift): hit-test usa `AXUIElementCopyElementAtPosition`; janela obtida por `AXWindow` ou ancestrais.
- [ActionExecutor.swift](https://github.com/mahirozdin/SmartClose/blob/v0.4.2/SmartCloseApp/Core/Interception/ActionExecutor.swift): usa `NSRunningApplication.terminate()`, respeitando encerramento normal e avisos de documentos. Não força término.
- [WindowClassifier.swift](https://github.com/mahirozdin/SmartClose/blob/v0.4.2/SmartCloseApp/Core/WindowModel/WindowClassifier.swift): exige janela normal com role `AXWindow` e subrole `AXStandardWindow`; diálogos e auxiliares têm tratamento conservador.

## Implicação para o Trio

**Inferência de implementação:** `AXUIElementPerformAction(..., kAXPressAction)` não percorre o mouseDown global observado pelo SmartClose. Não deve ser tratado como equivalente ao clique original, nem usado como fallback silencioso para o vermelho.

**Hipótese a validar no Mac:** ocultar a sobreposição, confirmar novamente PID/janela/botão/visibilidade, e postar um par mouseDown/mouseUp no centro do botão original em `.cghidEventTap`. Um post em `.cgSessionEventTap` fica abaixo do ponto de interceptação do SmartClose e não é o candidato apropriado para esse teste. A sobreposição precisa desaparecer antes do hit-test; apenas `ignoresMouseEvents` pode ser insuficiente para remover sua árvore de Acessibilidade do teste global.

Os controles desenhados pelo Trio não devem se anunciar como `AXCloseButton` de uma janela Trio: o clique físico inicial poderia acionar o SmartClose sobre o processo errado. O vermelho ampliado pode ter role de botão acessível e label clara, mantendo subrole genérica.

Trio não deve chamar `terminate()` por conta própria para imitar o SmartClose. Isso duplicaria políticas e mudaria comportamento em apps com múltiplas janelas.

## Teste necessário, sem dados do usuário

Usar um aplicativo de teste descartável AppKit, com uma janela padrão, sem documentos e `applicationShouldTerminateAfterLastWindowClosed = false`. Registrar `windowWillClose` e `applicationWillTerminate`, além de PID e presença da janela.

1. Com SmartClose mantido ativo e suas regras intactas, abrir a fixture e realizar `AXPress` em seu botão original. Medir janela fechada e se o processo continua ativo.
2. Abrir nova fixture limpa e encaminhar um par de eventos ao botão original via `.cghidEventTap`, sem sobreposição. Medir se o SmartClose pede término.
3. Repetir o mesmo teste pela interface ampliada Trio, ocultando a sobreposição antes do encaminhamento. Comparar com a etapa 2.
4. Repetir com duas janelas: fechar a primeira deve preservar processo/segunda janela; a última deve seguir SmartClose. Não inferir sucesso apenas porque uma janela desapareceu.
5. Validar clique direito em fundo/controles: nenhum evento esquerdo sintético e nenhuma ação de janela.

Teste em Codex deve priorizar alinhamento, hover, troca de foco e movimentação; não fechar a janela da conversa com dados do usuário para provar a integração.

## Estado desta investigação

Intercepção e diferenças entre caminhos de API: estabelecidas por fonte oficial da versão e corroboradas por evidência estática local. Compatibilidade runtime do clique encaminhado **diretamente ao original**: validada na fixture em 14/11/2026 (detalhes abaixo). Caminho completo começando na sobreposição Trio: **validado na fixture em 14/11/2026**, posteriormente ao teste direto; ver a seção final e `PIPELINE-VALIDATION.md`.


## Validação runtime na fixture (14/11/2026)

Teste executado por `Tools/SmartCloseCompatibilityTest.swift`, que só aceita bundle `com.allm4.TrioFixture`, exige uma única instância/janela padrão sem documentos e valida controles e permissões já existentes. Não pede permissões nem permite selecionar aplicativos arbitrários.

- **AXPress** (`build/smartclose-axpress-result.json`): resultado AX `0` (sucesso), janelas de 1 para 0, processo continuou ativo. O log registrou `windowWillClose`, sem encerramento. Isso confirma a diferença de comportamento nesta instalação.
- A fixture sem janelas foi encerrada como limpeza do teste e reaberta limpa.
- **Mouse HID ao botão original** (`build/smartclose-hid-result.json`): par `leftMouseDown`/`leftMouseUp` postado em `.cghidEventTap`; processo encerrou. Log `build/fixtures/hid-test.jsonl`: `applicationShouldTerminate`, `applicationWillTerminate`, `windowWillClose`. A fixture, por implementação, não encerra só porque sua última janela fechou. O mouseDown também não chegou ao monitor local da fixture, compatível com o SmartClose ter consumido o evento e solicitado término.
- As preferências do SmartClose permaneceram intactas. Nenhuma janela de documentos do usuário recebeu cliques de fechar.

Dois ensaios preliminares foram abortados **antes de postar clique**, pelas verificações: primeiro por interpretar um retângulo CG de camada alta como obstrução, depois por ausência de foco. O Mac mantém um overlay de brilho LUM4 (`com.allm4.lum4.personal`, layer 1001) e um retângulo Dock (layer 20) cobrindo o monitor na lista CG; eles não correspondem necessariamente a áreas interativas. Para o teste autorizado, a verificação conservou foco da fixture, primeiro retângulo de janela normal layer 0 e, decisivamente, hit-test global AX idêntico ao botão original. Nenhuma exclusão genérica deve ser aplicada ao produto sem validação de identidade e hit-test.

Esse resultado estabelece a integração do **evento HID no controle original** com o SmartClose instalado. Ainda faltam validar, como uma etapa separada, a ocultação e reexibição do painel Trio e o encaminhamento iniciado pelo seu botão ampliado.


## Validação completa pelo botão ampliado Trio

Em 14/11/2026, o harness `Tools/ExerciseOverlay.swift` foi compilado e executado contra o Trio instalado em `/Applications/Trio.app`, processo 18066. O programa só aceita a fixture própria, verifica que ela está ativa, exige identidade AX/CG da janela e do painel e comprova os três botões Trio por seus rótulos conhecidos. A opção de ativação só admite o bundle e caminho conhecidos da fixture; nenhum aplicativo com dados do usuário pode ser escolhido.

- **Amarelo:** o harness enviou um clique HID ao NSButton ampliado do Trio, que percorreu o fluxo real do produto. Resultado: `AXMinimized = true`, fixture viva, overlay removido ao minimizar (`build/exercise-click-yellow.json`).
- **Vermelho:** clique HID ao NSButton ampliado do Trio. O processo da fixture encerrou; o Trio continuou ativo. O log da fixture registra `applicationShouldTerminate`, `applicationWillTerminate`, `windowWillClose` (`build/exercise-click-red.json`, `build/fixtures/pipeline-red.jsonl`). A fixture não encerra ao simplesmente fechar sua última janela. Isso valida o encaminhamento real pelo Trio com o SmartClose instalado, além do teste direto anterior.
- **Verde:** dois cliques reais pelo mesmo harness maximizaram sem fullscreen e restauraram exatamente a geometria anterior (`build/exercise-click-green-maximize.json`, `build/exercise-click-green-restore.json`).

Limites desse resultado: esses cliques foram validados em uma fixture padrão, sem documentos. Não comprovam cobertura universal. O teste sintético de movimento até o verde preservou a janela e o painel de controles, mas não abriu o menu nessa rodada; esse resultado permanece registrado separadamente, sem presumir equivalência com hover físico.
