# Validação do caminho real dos controles

14/11/2026, macOS 27.2.1, Apple Silicon. Trio instalado em `/Applications/Trio.app`, processo 18066 durante os testes. A fixture própria não contém documentos e mantém seu processo vivo ao fechar a última janela.

Harness: `Tools/ExerciseOverlay.swift`, compilado em `build/ExerciseOverlay`. Todos os eventos desta rodada foram direcionados exclusivamente ao bundle `com.allm4.TrioFixture` e ao painel Trio que cobre seus controles. Nenhum clique foi enviado ao Codex, Edge, Antigravity ou outro aplicativo do usuário por esse harness.

## Verificações antes de cada evento

- Uma instância fixture e uma instância Trio, com a fixture em primeiro plano.
- Janela AX padrão não minimizada, três controles habilitados e geometria válida.
- Correspondência única da janela na lista pública CG e painel Trio normal dentro da região esquerda permitida, até cinco pontos depois do verde original.
- Hit-test AX global retornando PID Trio, role `AXButton` e rótulo exato do controle próprio. O ponto clicado está dentro do painel e pertence ao painel normal superior nessa região.
- Permissões já existentes de Acessibilidade e envio de eventos. Nenhuma nova permissão foi solicitada.
- Para ativar a fixture, o harness só aceita o bundle e caminho da própria fixture compilada, com `NSRunningApplication.activate` e fallback LaunchServices. Não permite escolher PID ou aplicativo arbitrário.

O frame AX dos NSButtons inclui um anel de aproximadamente um ponto ao redor do frame CG do painel. O harness admite dois pontos apenas nessa comparação de bounds, preservando a prova do rótulo/PID e o ponto de clique dentro do painel real.

## Resultados

| Ação pelo controle Trio | Resultado observado | Evidência local |
|---|---|---|
| Amarelo | Janela minimizada, processo fixture vivo, overlay retirado | `build/exercise-click-yellow.json` |
| Vermelho | Processo fixture encerrado normalmente, Trio vivo; fixture registrou solicitação e término | `build/exercise-click-red.json`, `build/fixtures/pipeline-red.jsonl` |
| Verde, primeiro clique | Frame `(260,1024,680,492)` passou a `(0,49,2624,1567)`; `AXFullScreen = false` | `build/exercise-click-green-maximize.json` |
| Verde, segundo clique | Frame restaurado exatamente a `(260,1024,680,492)`; `AXFullScreen = false` | `build/exercise-click-green-restore.json` |
| Movimento sintético até o verde, sem clique | Fixture permaneceu ativa/viva e controles presentes; só um painel Trio foi encontrado, sem menu visível | `build/exercise-hover-green.json` |

O amarelo e o vermelho foram exercitados com um par mouseDown/mouseUp entrando no NSButton do Trio, que então executou seu próprio encaminhamento. Não foi usado AXPress para contornar o produto. O vermelho preservou a integração com SmartClose nesta fixture.

## Pendências e observações

O menu de organização não abriu no ensaio com mouseMoved sintético, inclusive após afastar o ponteiro e voltar ao verde. Não se declara esse ensaio aprovado; ele também não estabelece o comportamento de todos os eventos físicos de hover.

Uma corrida de inicialização foi reproduzida em novas instâncias da fixture: no primeiro foco, o painel podia permanecer ausente; ao reativar a fixture, o painel aparecia. O agente principal recebeu a hipótese de que a primeira atualização ocorra antes da janela AX ficar pronta e que a inscrição tardia após lançamento precise solicitar nova atualização. Isso é uma observação da build testada, não um resultado atribuído a uma futura correção.

Ensaios preliminares abortaram sem postar eventos por falta de foco, ausência do painel, ou bounds AX ligeiramente maiores que o painel. Os arquivos de resultado finais listados acima correspondem aos testes efetivamente executados. Janelas e processos fixture de rodadas anteriores foram encerrados apenas como limpeza de testes próprios, sem arquivos do usuário.


## Rodada com animação e estabilidade (Trio processo 20910)

A build instalada com `WindowAnimator` de duração nominal 220 ms foi testada em seguida, antes de uma nova reinstalação/cold start feita pela sessão principal. Os resultados desta seção pertencem ao processo 20910; não são atribuídos automaticamente a binários instalados depois.

| Ensaio | Resultado observado | Evidência local |
|---|---|---|
| Nova fixture 22086 | Sua janela inicial foi maximizada automaticamente na área útil. Uma captura inicial do harness foi rejeitada por ainda usar a geometria anterior à animação; uma nova leitura confirmou a geometria final. | `build/fixtures/new-build-pipeline.jsonl`, `build/new-probe.json` |
| Restaurar animado | 15 geometrias distintas nos primeiros 300 ms; frame final exatamente `(260,1024,680,492)`, sem fullscreen | `build/new-green-restore.json` |
| Maximizar animado | 15 geometrias distintas nos primeiros 300 ms; frame final `(0,49,2624,1567)`, sem fullscreen | `build/new-green-maximize.json` |
| Restaurar novamente | 15 geometrias distintas nos primeiros 300 ms; restauração exata da geometria anterior, sem fullscreen | `build/new-green-restore-final.json` |
| Três cliques no conteúdo da fixture | O mesmo painel de controles, ID CG 1294, esteve presente em todas as 30 amostras; nenhuma janela foi organizada/fechada por esses cliques | `build/new-content-clicks.json` |
| Amarelo ampliado | Janela minimizada, processo fixture vivo | `build/new-click-yellow.json` |
| Vermelho ampliado | Fixture 23286 solicitou e concluiu término normal; Trio permaneceu vivo | `build/new-click-red.json`, `build/fixtures/new-red-pipeline.jsonl` |

Os cliques continuaram restritos à fixture e a controles Trio comprovados por AX/CG. A preferência Reduzir Movimento estava desativada durante a amostragem da animação. Os frames intermediários foram lidos efetivamente por AX, não inferidos do código da animação. Em cada percurso houve 13 geometrias distintas até 230 ms; o frame final foi observado entre 255 e 264 ms após o mouseUp, incluindo entrega do evento e chamadas AX.

O hover sintético continua sendo uma limitação do harness: a posição de `CGEvent(mouseMoved)` não coincidiu de forma estável com `NSEvent.mouseLocation`, que o menu consulta para decidir se deve permanecer aberto. Esse ensaio não é usado para afirmar que o hover físico falha nem para certificar visualmente o tamanho desenhado dos círculos. A confirmação do percurso físico do menu ocorreu na sessão principal com o usuário. Não houve captura de tela, nova permissão ou clique em aplicativos do usuário nesta rodada.

Ao concluir, nenhum ensaio permaneceu executando. A última fixture foi encerrada pelo próprio teste vermelho. O agente não encerrou nem reinstalou o Trio; o cold start e a configuração de início automático/Acessibilidade ficaram sob responsabilidade da sessão principal.


## Ordem das janelas após elevar o painel (Trio processo 25086, build 3)

A checagem anterior de presença/ID não estabelecia a ordem de empilhamento. A sessão principal identificou o painel normal atrás de uma janela de aplicativo e mudou o painel de controles e o de organização para o nível flutuante público (`floating`, layer CG 3). Esta rodada verificou explicitamente a ordem CG após levantar as próprias janelas de teste.

O harness foi adaptado para aceitar o painel Trio no layer 3, registrar sua posição na lista CG e exigir o hit-test AX dos rótulos próprios antes de qualquer clique. Foi aberta uma única instância da fixture, processo 25467, com duas janelas padrão próprias. Como o início automático as maximiza, a preparação colocou as duas em geometrias diferentes por setters públicos AX, evitando a ambiguidade de duas janelas do mesmo PID com bounds idênticos.

| Percurso | Geometria da janela testada | Ações | Resultado | Evidência |
|---|---|---|---|---|
| Primeira janela | `(180,260,900,620)` | 3 ativações/AXRaise e 3 cliques no conteúdo | 30 amostras: painel 1544, layer 3, sempre antes/acima da janela layer 0 | `build/zorder-content-first.json` |
| Segunda janela | `(440,500,860,620)` | AXRaise para trocar foco, mais 3 ativações/AXRaise e 3 cliques | 32 amostras: painel reposicionado e sempre acima da segunda janela | `build/zorder-content-second.json` |
| Volta à primeira | `(180,260,900,620)` | AXRaise para trocar foco, mais 3 ativações/AXRaise e 3 cliques | 33 amostras: mesmo painel retornou à primeira janela e permaneceu acima | `build/zorder-content-return.json` |

Total: **9 AXRaise, 9 cliques e 95 amostras** com a ordem esperada. Não foi usado apenas `isVisible`: o campo `overlayAboveFixtureThroughoutContentClicks` compara layer e índice CG do painel com a janela alvo em cada amostra. A amostragem dos cliques começou depois de a troca de foco e a geometria estarem confirmadas; não estabelece ausência de qualquer latência inferior a essa janela de observação.

Uma tentativa preliminar na volta à primeira janela abortou antes de clicar porque o hit-test AX não comprovou os três rótulos. A repetição foi aprovada sem relaxar esses guardas. As tentativas de hover automatizado desta rodada também não produziram uma certificação do menu: um guarda AX interrompeu o percurso antes de concluir os movimentos necessários. Não se atribui esse resultado a uma falha física do menu nem se declara esse teste aprovado. A confirmação física do usuário na sessão principal é uma evidência separada.

Nenhuma interação foi enviada ao Codex ou a outro aplicativo do usuário. O Trio não foi parado pelo harness. Ao terminar, a fixture ficou viva e foi ocultada, sem ensaio em execução, deixando a sessão principal livre para o build e a instalação finais. Os resultados desta seção pertencem ao processo 25086; não certificam automaticamente binários posteriores.

## Movimento e acompanhamento: build 4, processo 26340

Nesta rodada foi medido o deslocamento efetivo do painel em relação aos bounds da janela **na mesma captura CG**, usando como referência o deslocamento inicial da âncora. A presença do painel não foi considerada prova de alinhamento. Os eventos físicos sintéticos e as alterações se restringiram à fixture 25467; nenhum aplicativo do usuário recebeu ações.

| Ensaio | Resultado | Evidência |
|---|---|---|
| Arrasto manual pela barra, 10 passos em aproximadamente 200 ms | Janela mudou de `(180,260)` para `(359,359)`. Em 7 das 14 amostras, o painel permaneceu visível com atraso de 18 px em X e 10 px em Y. Após 70/150/300 ms de repouso, alinhamento exato. **Acompanhamento durante arrasto não aprovado.** | `build/build4-drag.json` |
| Resize pelo canto inferior direito | Janela passou de 900×620 a 1044×710, mesma origem `(359,359)`. Painel visível e alinhado nas 14 amostras, incluindo leituras após 70/150/300 ms. | `build/build4-resize.json` |
| Verde para maximizar | 13 geometrias distintas, destino `(0,49,2624,1567)`, sem fullscreen. Porém houve 11 amostras visíveis fora da âncora durante a animação. | `build/build4-green-maximize.json` |
| Verde para restaurar | 13 geometrias distintas e restauração exata a `(359,359,1044,710)`, sem fullscreen. Porém houve 11 amostras visíveis fora da âncora, com maior desvio medido de 118×102 px. | `build/build4-green-restore.json` |

A função dos cliques verde e a geometria final foram confirmadas; o acompanhamento visual durante a interpolação **não foi aprovado nesta build**. A recomendação transmitida à sessão principal foi ocultar o painel durante movimento que não possa ser acompanhado de forma confirmada e reapresentá-lo após a posição final segura. O usuário havia autorizado esse comportamento para movimento/redimensionamento manual. O resultado programático permanece uma observação separada: um fallback apenas manual não comprova correção da interpolação do verde.

A sessão principal interrompeu a rodada para instalar uma versão seguinte do auxiliar/inicialização e do fallback manual. Nenhuma aprovação destes resultados se transfere a essa versão futura sem novo ensaio. Os testes de snap esquerda/direita/centralizar desta rodada não chegaram a ser executados antes da interrupção. A fixture foi deixada viva e oculta; não há ensaio ativo. O agente não parou o Trio.
