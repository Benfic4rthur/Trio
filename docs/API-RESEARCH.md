# Trio — investigação de APIs públicas

Consulta: 14 de novembro de 2026. Ambiente informado pelo sistema local: macOS 27.2.1 (26B131), Apple Silicon arm64, SDK macOS do Xcode instalado, Swift 6.4.2. Este documento registra viabilidade e escolhas de protótipo; não equivale a teste de funcionamento nem certificação de compatibilidade.

## O que as APIs permitem

O AppKit oferece `NSWindow.standardWindowButton(_:)` para obter os botões na hierarquia de **janelas pertencentes ao próprio processo**. Não oferece um mecanismo público para substituir, ampliar ou esconder os botões de todos os aplicativos. `NSApplication.window(withWindowNumber:)` tampouco retorna objetos `NSWindow` de outro aplicativo.

O Trio pode criar uma janela própria e usar Acessibilidade para consultar a posição e o tamanho da janela alvo e seus botões. Isso é uma sobreposição independente, cuja segurança depende de verificar continuamente a validade do alvo **quando acontecem eventos**, sem pressupor suporte universal.

Fontes:

- [NSWindow.standardWindowButton](https://developer.apple.com/documentation/appkit/nswindow/standardwindowbutton(_:))
- [NSApplication.window(withWindowNumber:)](https://developer.apple.com/documentation/appkit/nsapplication/window(withwindownumber:))
- [AXUIElement.h](https://developer.apple.com/documentation/applicationservices/axuielement_h)

## Descoberta e identidade da janela

Usar `AXUIElementCreateApplication(pid)`, `kAXFocusedWindowAttribute`, `kAXCloseButtonAttribute`, `kAXMinimizeButtonAttribute`, `kAXZoomButtonAttribute`, `kAXPositionAttribute` e `kAXSizeAttribute`. Atributos e chamadas podem falhar, ser omitidos ou ter implementação incompleta. O protótipo deve recusar a janela quando faltar geometria confiável, quando houver diálogo/sheet ou quando os controles não forem reconhecíveis.

O SDK descreve posições AX em pontos, com origem no topo esquerdo do monitor da barra de menus, eixo Y crescendo para baixo. AppKit usa coordenadas de tela com Y crescendo para cima. Converter usando a altura/origem da tela primária, incluindo monitores com coordenadas negativas, sem supor que o monitor principal seja o único monitor.

`CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)` fornece janelas visíveis em ordem de frente para trás, com PID, bounds, layer e ID. Associar ao elemento AX somente quando a combinação **PID + bounds** produzir uma correspondência única, com tolerância pequena para arredondamento. Se duas janelas coincidirem, rejeitar. Validar novamente antes de agir. Não usar o título como identidade, pois ele muda e pode não estar disponível sem autorização adicional.

Não há constante pública `kAXWindowNumber` no header AX instalado. Não usar `_AXUIElementGetWindow`, atributos privados ou mecanismos de injeção. A igualdade de elementos AX deve usar `CFEqual`, não um título.

Fontes:

- [CGWindowListCopyWindowInfo](https://developer.apple.com/documentation/coregraphics/cgwindowlistcopywindowinfo(_:_:))
- [optionOnScreenOnly: ordem front to back](https://developer.apple.com/documentation/coregraphics/cgwindowlistoption/optiononscreenonly)
- [Window list option constants](https://developer.apple.com/documentation/coregraphics/window-list-option-constants)
- [Apple WWDC19: metadados de janelas e privacidade](https://developer.apple.com/videos/play/wwdc2019/701/?time=986)

Observação de privacidade: não inferir permissão de gravação de tela a partir de um campo ausente. A política dos campos retornados pode mudar. O protótipo não necessita capturar pixels nem pedir Gravação de Tela para obter bounds/PID; se informações necessárias não vierem, deve recusar o alvo. A própria Apple considera a geração da lista de janelas relativamente cara, portanto a consulta deve ocorrer por necessidade/evento.

## Eventos, movimento, Spaces e monitores

`AXObserverCreate` cria observador por PID. Adicionar sua fonte ao run loop e registrar notificações. A documentação permite registrar no elemento de aplicação para observar eventos de seus elementos; notificações não suportadas devem ser tratadas como falta de cobertura.

Eventos relevantes: foco/main window alterados, janela criada, movida, redimensionada, minimizada/restaurada, elemento destruído e aplicação mostrada/escondida. Associar também notificações públicas do `NSWorkspace`: ativação/desativação de aplicativos, encerramento, `activeSpaceDidChangeNotification`, sessão inativa, sono/despertar. `NSApplication.didChangeScreenParametersNotification` permite recalcular monitores.

Escopo inicial: somente a janela ativa de outro aplicativo, com geometria e identidade confirmadas. Remover imediatamente a sobreposição ao mudar foco/aplicativo/Space, ao iniciar transição ou ao receber destruição/minimização. Só mostrá-la após nova validação. Não manter uma sobreposição flutuante de último alvo válido quando a descoberta falhar. Um breve acompanhamento durante arraste pode complementar notificações deficientes, com duração limitada e encerramento ao soltar o mouse; evitar polling permanente a 30/60 Hz.

`NSWindow.CollectionBehavior` controla participação em Spaces/Mission Control/Stage Manager, mas não liga uma janela própria à janela de outro processo. `canJoinAllSpaces` sozinho permite que uma sobreposição apareça no Space errado. Propriedades como `.transient` podem ajudar a escondê-la no Mission Control, mas o comportamento deve ser testado. Não existe, nas APIs citadas, uma única notificação pública que garanta acompanhamento perfeito de toda animação de Mission Control, Stage Manager e troca de Spaces.

Fontes:

- [AXNotificationConstants.h](https://developer.apple.com/documentation/applicationservices/axnotificationconstants_h)
- [AXObserver e funções AX](https://developer.apple.com/documentation/applicationservices/axuielement_h)
- [NSWorkspace.activeSpaceDidChangeNotification](https://developer.apple.com/documentation/appkit/nsworkspace/activespacedidchangenotification)
- [NSWindow.CollectionBehavior](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct)
- [NSApplication.didChangeScreenParametersNotification](https://developer.apple.com/documentation/appkit/nsapplication/didchangescreenparametersnotification)

## Área disponível e aparência

As APIs AX fornecem bounds e semântica dos elementos que o aplicativo expõe. Não descrevem de forma universal uma região livre de ferramentas ao redor dos botões. Alguns elementos decorativos ou desenhados manualmente podem nem aparecer na árvore AX. Logo, uma inspeção AX não prova que uma área esteja visualmente vazia em todos os aplicativos.

O protótipo deve limitar o tamanho à área comprovadamente reservada no perfil testado ou a uma faixa conservadora validada por hit testing, e recusar em caso de dúvida. O limite de 5× é um máximo configurável; em uma barra comum, um botão com aproximadamente 60 pontos de diâmetro frequentemente não cabe. Não deve ultrapassar ferramentas para satisfazer o valor solicitado.

Uma máscara opaca pode esconder os botões originais, mas as APIs públicas citadas não fornecem a cor/material exatos de qualquer barra de título externa. Uma composição translúcida pode deixar os controles pequenos visíveis. É necessário validar visualmente cada abordagem e não prometer correspondência perfeita em barras personalizadas, fundos dinâmicos ou transparência.

## Clique original, Acessibilidade e Smart Close

`AXUIElementPerformAction(button, kAXPressAction)` solicita uma ação sem gerar necessariamente a mesma sequência de mouse. Um utilitário que intercepta mouse-down/mouse-up pode não observar essa ação.

`CGEvent(mouseEventSource:mouseType:mouseCursorPosition:mouseButton:)` cria eventos de mouse; `post(tap:)` os publica no fluxo global. O SDK documenta que `CGEventPost` insere o evento antes dos taps daquela localização e passa por eles. `postToPid` publica no fluxo do processo alvo e não substitui um teste de integração com um interceptador global.

Para o vermelho, o candidato a validar é: capturar clique explícito na sobreposição; confirmar mesmo PID, elemento AX e janela CG; esconder a sobreposição; validar o alvo e hit test do centro do botão original; encaminhar mouse-down e mouse-up para esse centro via fluxo global. Abortar se houver divergência. Não converter silenciosamente uma falha em `AXPress`, `terminate()` ou Command-Q. Se o aplicativo/middleware ignorar eventos sintéticos, registrar incompatibilidade. Cliques sintéticos podem produzir movimento perceptível do cursor, o que também exige teste. Não restaurar o cursor sem verificar se o usuário já o moveu.

A equivalência com Smart Close só pode ser declarada após comparar o clique original com o clique encaminhado, no Smart Close instalado. Eventos publicados podem ser identificáveis como sintéticos e o interceptador pode decidir ignorá-los. A documentação não promete compatibilidade entre utilitários independentes.

`CGPreflightPostEventAccess` consulta o acesso de envio; `CGRequestPostEventAccess` o solicita. Solicitar Acessibilidade quando necessária, sem pedir Input Monitoring ou Screen Recording por conveniência. O protótipo não precisa instalar um event tap global para capturar todos os cliques: a própria janela de sobreposição recebe seus cliques e movimentos locais.

Fontes:

- [CGEvent](https://developer.apple.com/documentation/coregraphics/cgevent)
- [CGEvent.post(tap:)](https://developer.apple.com/documentation/coregraphics/cgevent/post(tap:))
- [Funções Core Graphics e autorizações](https://developer.apple.com/documentation/coregraphics/core-graphics-functions)
- [CGEventPostToPSN: contraste entre encaminhamento global e por processo](https://developer.apple.com/documentation/coregraphics/cgevent/posttopsn(processserialnumber:))
- [AXUIElementPerformAction](https://developer.apple.com/documentation/applicationservices/axuielementperformaction(_:_:))

## Minimizar, maximizar e restaurar

O amarelo pode encaminhar clique ao botão original após validação, ou usar a ação AX apenas se o comportamento tiver sido validado e não alterar a integração desejada. Nunca agir em mouse-enter.

O verde do Trio deve escrever posição e tamanho da janela via AX, após verificar `AXUIElementIsAttributeSettable`, usando `NSScreen.visibleFrame` convertido para AX. Não clicar no botão verde nativo: ele pode iniciar tela cheia. Guardar o retângulo anterior por identidade de janela e restaurar somente a mesma janela ainda válida. Apps podem impor tamanho mínimo/máximo ou recusar a geometria; ler novamente após a alteração e informar a limitação.

O menu de organização pode ser uma janela/popup própria aberta após hover breve e cancelável no verde. Suas ações também precisam validar o alvo antes de escrever a geometria. Hover nos botões vermelho e amarelo deve apenas desenhar feedback. O botão direito no fundo ou em um botão deve abrir exclusivamente o menu “Abrir Trio”, sem propagar fechamento/minimização/maximização.

Fontes:

- [AXUIElementIsAttributeSettable e AXUIElementSetAttributeValue](https://developer.apple.com/documentation/applicationservices/axuielement_h)
- [NSScreen.visibleFrame](https://developer.apple.com/documentation/appkit/nsscreen/visibleframe)

## Aplicativo fantasma e abertura manual

`LSUIElement = true` declara um agente sem presença permanente no Dock. Não criar `NSStatusItem`, portanto nenhuma presença na barra de menus. Configurações podem adotar temporariamente a política `.regular` e, ao esconder/fechar, voltar a `.accessory` mantendo o processo e os controles. `applicationShouldTerminateAfterLastWindowClosed` deve retornar `false`. Encerrar explicitamente deve parar os observadores e terminar o processo.

O Launch Services normalmente reabre a instância do bundle já em execução; implementar `applicationShouldHandleReopen(_:hasVisibleWindows:)` para mostrar a janela existente. Um bloqueio adicional por processo pode proteger contra execução direta acidental de um segundo binário, se necessário; não usar `open -n` no fluxo comum.

`SMAppService.agent(plistName:)` com um LaunchAgent incorporado ao bundle e argumento explícito `--background` distingue inicialização automática da abertura manual. O plist fica em `Contents/Library/LaunchAgents`, com `BundleProgram` relativo ao bundle. Não usar `KeepAlive = true` se isso fizer “Encerrar Trio” reiniciar imediatamente o agente. Consultar o status de autorização, tratar erros e refletir o estado real nas configurações. Não editar `~/Library/LaunchAgents` diretamente nem pedir senha de administrador para um agente de sessão.

Alternativa pública: `SMAppService.mainApp`, detectando o parâmetro `keyAEPropData` do evento `kAEOpenApplication`, cujo valor é `keyAELaunchedAsLogInItem` ou `keyAELaunchedAsServiceItem`; nesse lançamento, não abrir configurações. O argumento explícito do agente incorporado elimina a dependência dessa detecção para o protótipo.

Fontes:

- [LSUIElement](https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement)
- [NSApplicationDelegate](https://developer.apple.com/documentation/appkit/nsapplicationdelegate)
- [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
- [Estrutura de helpers e BundleProgram](https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos)
- [Constantes de lançamento Apple Event](https://developer.apple.com/br/documentation/coreservices/apple_events/1556410-launch_apple_event_constants)

## Validações ainda necessárias

- Aparência e oclusão dos controles pequenos em barra padrão e personalizada, em claro/escuro.
- Smart Close: fechar janela descartável pelo botão original e pelo botão do Trio, comparando encerramento real do processo e sequência interceptada.
- Minimizar, maximizar sem full screen e restaurar, incluindo aplicativos que impõem geometria.
- Codex e outro aplicativo de barra personalizada; ignorar com segurança os incompatíveis.
- Mudança de foco, arraste/redimensionamento, Spaces, Mission Control, Stage Manager, monitores e sono/despertar.
- Abertura automática sem UI, reabertura manual sem segundo processo, “Esconder Trio”, botão direito sem ações colaterais e encerramento explícito.

Ausência de teste em um cenário deve constar como pendente, sem ser convertida em alegação de compatibilidade.
