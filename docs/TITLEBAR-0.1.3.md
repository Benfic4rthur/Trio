# Cliques na barra — 0.1.3, build 10

O pressionamento na região de arrasto era interpretado como início de movimento e ocultava o painel antes de existir arrasto. Isso fazia o Trio piscar em cliques sem mudança da janela.

Agora o mouse-down apenas registra a intenção em uma região previamente verificada por AX e CG. O mouse-dragged com deslocamento de pelo menos 2 pt inicia a ocultação. Mouse-up e ocultação limpam a intenção; a verificação de janela e aplicativo continua obrigatória. Não foi adicionado timer contínuo.

## Evidências

Ensaio restrito à fixture AppKit descartável, com prova de caminho, PID, janela frontal e hit-test antes dos eventos. Nenhuma ação foi enviada às janelas pessoais do Codex ou Edge.

| Ensaio | Resultado |
| --- | --- |
| 0.1.2 instalada, três cliques parados na barra | 56 de 72 amostras sem painel; moldura da janela inalterada. |
| 0.1.3 instalada, mesmos três cliques | Zero de 72 amostras sem painel; moldura inalterada. |
| Pressão mantida antes do arrasto | Painel visível. |
| Arrasto real em seis passos e soltura | Janela moveu; painel oculto durante movimento e reapresentado após soltar. |
| Testes existentes | 25 passaram. |
| Rodada adicional de ações | Dez cliques de conteúdo sem sumiço, deslocamento da linha nativa acompanhado, verde restaurou, amarelo minimizou. Na primeira tentativa o vermelho não fechou; na repetição fechou e Smart Close encerrou a fixture. Não foi identificada a causa da primeira tentativa; isso permanece uma limitação do ensaio. |

A pedido do usuário, os testes foram encerrados após essa rodada. Não há certificação universal, teste físico Intel ou nova validação de bloqueio/desbloqueio nesta build; a confirmação física do usuário pertence à 0.1.2. Tamanho salvo 1,3×, início automático e permissões foram conferidos no diagnóstico da instalação 0.1.3.

Os JSONs estão em [validation/0.1.3-build10](validation/0.1.3-build10/).
