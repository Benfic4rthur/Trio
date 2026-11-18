# Claude e elementos vazios — 0.1.4, build 11

Em 18/11/2026, o Trio 0.1.3 estava rodando desde o início da sessão, com controles habilitados, Acessibilidade e envio de eventos autorizados. O LoginItem estava habilitado e seu auxiliar havia saído normalmente. A ausência dos controles na foto não era causada por falta de permissão ou falha de inicialização.

## Causa observada

A inspeção estrutural, sem ler títulos, texto ou documentos, confirmou três botões habilitados e uma correspondência única entre a janela AX e CG do Claude. A análise de obstáculos falhava no 32º nó: um `AXGroup` de tamanho **1×0 pt**, posição **(0, 1615)**, longe da reserva dos controles **(1, 50, 84, 44)**. A função que exige dimensões positivas para controles também era usada nessa inspeção. O nó vazio invalidava a análise inteira e o Trio recusava a janela.

A correção separa a geometria da inspeção da geometria de controles e ações. Dimensões finitas e não negativas podem ser lidas durante a inspeção; um nó vazio ancorado fora da reserva pode ser descartado. Nós vazios dentro da reserva, dimensões negativas/não finitas e erros de leitura continuam impedindo a confirmação de espaço livre. Janelas, botões e ações continuam exigindo retângulos estritamente positivos. Não há lista de exceção que ignore todas as verificações para Claude.

## Validação e limites

- Antes da correção: a inspeção do Claude falhava no grupo 1×0, apesar dos três controles disponíveis.
- Com o código corrigido, na mesma janela real: inspeção completa, sem obstáculos na reserva e layout **1,3×**; Edge e Codex também mantiveram seus layouts de 1,3×. Nenhum clique foi enviado por esses diagnósticos.
- **25 testes existentes passaram.** App e auxiliar compilados em arm64 e x86_64, com assinatura local verificada.
- **0.1.4, build 11 instalada** com permissões, início automático e tamanho 1,3× preservados. O painel do Trio foi observado em execução no aplicativo ativo após a instalação.
- A captura da janela do Claude por automação introduziu o indicador de compartilhamento do macOS sobre os controles e alterou sua geometria. Essa captura não serve como confirmação visual do overlay no Claude; o indicador é um obstáculo real que o Trio deve respeitar. Não foi usado como justificativa para ignorar ferramentas ou desenhar sobre o indicador.
- As ações de fechar/minimizar/maximizar não mudaram e não foram novamente disparadas nos aplicativos pessoais. Não houve novo ensaio de bloqueio/desbloqueio ou teste físico Intel. Os resultados não prometem compatibilidade com toda janela de todo aplicativo.

Não foram acrescentados timers, varreduras contínuas, permissões, injeção ou APIs privadas. A correção usa a leitura pública de atributos da [Acessibilidade da Apple](https://developer.apple.com/documentation/applicationservices/1462085-axuielementcopyattributevalue).

Diagnósticos estruturais: [validation/0.1.4-build11](validation/0.1.4-build11/). Não incluem conteúdo das conversas.
