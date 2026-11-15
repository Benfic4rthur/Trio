# Correção de alinhamento e retomada — 0.1.2, build 9

Em 15/11/2026 o usuário mostrou círculos menores abaixo dos controles e relatou desaparecimento após bloquear/desbloquear, seguido de instabilidade em cliques normais.

## Reprodução e correção

Uma fixture própria deslocou os três botões nativos em 4 pt, mantendo a moldura da janela inalterada. Na build 8, a linha dos controles nativos foi de 65 para 69, enquanto o painel ficou em 65. Na versão instalada 0.1.2, ambos terminaram em 69. Isso reproduz uma causa concreta de discos nativos descobertos; a foto, isoladamente, não identifica toda a sequência que ocorreu no Codex.

O motor passa a observar movimentos dos controles, mudanças de layout da janela e foco interno. A verificação visual compara os três retângulos sem refazer a árvore inteira em cada clique. Layouts internos de conteúdo são agrupados. A camada transparente é limpa antes do redesenho, e a configuração restabelece a origem completa da view.

A retomada descarta painel e handles antigos e reconecta as observações, preservando preferências e restauração de tamanho. Usa NSWorkspace e os nomes públicos de CGSession.h (`kCGNotifyGUIConsoleSessionChanged` e `kCGNotifyGUISessionUserChanged`). Não usa chaves privadas de bloqueio, injeção, gravação de tela ou alteração de proteções. A sequência automática tem cinco tentativas até 3 s, canceladas ao recuperar o desenho, e uma recuperação pelo primeiro movimento do mouse; não existe um timer periódico em repouso.

## Resultados

| Ensaio | Resultado |
| --- | --- |
| Testes existentes | 25 passaram. |
| Desenho real da view em bitmap reutilizado | Cinco hovers e retorno: pixels iguais ao repouso, sem sobras; origem zerada. O código anterior falhou nos dois critérios. |
| Mudança dos botões com moldura estável | Falha reproduzida na build 8; corrigida na build 9 instalada. |
| Notificações locais de tela, sessão e repouso | Três ciclos ocultaram durante suspensão e recuperaram sem clique. São simulações dos callbacks, sem bloquear o Mac. |
| Cliques de conteúdo na versão instalada | Dez cliques, 60 amostras, nenhum painel ausente. |
| Verde na versão instalada | Mudou a geometria e restaurou o estado anterior no segundo clique. |
| Amarelo na versão instalada | Minimizou a fixture; restauração AX somente para preparar o teste seguinte. |
| Vermelho na versão instalada | Clique real no Trio, encaminhado ao original, fechou a fixture e o Smart Close encerrou seu processo. Trio permaneceu vivo. |
| Bloqueio/desbloqueio físico | Confirmado pelo usuário: “A parte do bloqueio funcionou”. Não houve automação de senha ou biometria. |

Os testes controlaram somente a fixture descartável. Nenhuma ação foi enviada às janelas pessoais do Codex ou Edge. Os resultados não representam compatibilidade universal. Intel físico, monitores adicionais e cobertura completa de Spaces continuam pendentes. O comportamento em segundo plano permanece o da janela ativa compatível.

JSONs e renders estão em [validation/0.1.2-build9](validation/0.1.2-build9/). O executável de teste verifica o caminho e o bundle da fixture, foco, identidade CG e hit-test AX antes de postar os cliques. Uma tentativa foi abortada por ausência de primeiro plano antes de qualquer clique e não foi contada como resultado do produto.
