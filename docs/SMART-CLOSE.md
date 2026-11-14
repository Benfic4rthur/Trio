# SmartClose: investigação de compatibilidade

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

Intercepção e diferenças entre caminhos de API: estabelecidas por fonte oficial da versão e corroboradas por evidência estática local. Compatibilidade runtime do clique encaminhado: **a validar**. Não se deve declarar integração concluída apenas com essa análise.
