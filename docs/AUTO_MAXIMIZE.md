# Automaximização conservadora

Só se aplica a janelas novas. O verde manual continua disponível para as janelas que permitem redimensionar, independentemente deste filtro de tamanho.

Uma candidata precisa ser uma janela padrão de aplicativo regular, estar na camada normal e no Space visível, permitir mover e redimensionar e expor os três controles padrão habilitados. Janelas modais, folhas anexas, auxiliares, minimizadas, em tela cheia e aplicativos nas exceções ficam como abrem. Metadados insuficientes ou uma árvore de filhos extensa também fazem o Trio recusar a mudança automática.

O tamanho mínimo é o maior entre 42% de cada dimensão útil do monitor e 900 × 600 pontos. Em telas pequenas, o limite de pontos é reduzido para 75% da dimensão útil, para permanecer alcançável. A janela também precisa ocupar pelo menos 30% da área útil e ter 90% de sua própria área dentro dela. Janelas já maximizadas não recebem nova operação nem um tamanho anterior fictício.

Estudo com dimensões de janela externas, sem abrir ou redimensionar aplicativos pessoais:

| Área útil em pontos | Janela | Resultado |
| --- | --- | --- |
| 2624 × 1568, monitor lido em 20/11/2026 | 680 × 482 | Mantém o tamanho |
| 2624 × 1568 | 900 × 600 | Mantém o tamanho |
| 2624 × 1568 | 1100 × 800 | Mantém o tamanho |
| 2624 × 1568 | 1400 × 700 | Mantém o tamanho |
| 2624 × 1568 | 1400 × 900 | Maximiza se os demais critérios forem atendidos |
| 2624 × 1568 | 1800 × 1200 | Maximiza se elegível |
| 1440 × 875 | 900 × 600 | Maximiza se elegível |
| 1440 × 875 | 800 × 500 | Mantém o tamanho |
| 1024 × 550 | 900 × 500 | Maximiza se elegível |

São critérios de conveniência, não uma identificação perfeita da finalidade de qualquer janela. Uma janela auxiliar que imite todos os atributos de uma janela principal grande pode exigir uma exceção por aplicativo. O monitor atual foi apenas consultado; os outros tamanhos são cenários sintéticos reproduzidos pelos testes.

## Eventos e corridas

AXWindowCreated e as duas pesquisas após lançamento entram na mesma fila, deduplicada por PID e identidade AX. Cada janela conserva sua própria estabilização: precisa manter o mesmo quadro por 180 ms, com até dez observações e prazo total de 1,6 s. A fila trabalha somente após eventos e fica sem timers quando termina.

Uma operação automática espera o encaminhamento de cliques ou uma animação existente, sem cancelar essa operação. Um gesto do usuário ou uma organização manual consome a pendência. A identidade da instância do aplicativo é revalidada; fechamento, término, suspensão, pausa e desativação descartam pendências. A memória de janelas processadas dura até sua destruição ou término do aplicativo, impedindo que a pesquisa tardia de lançamento maximize novamente uma janela já restaurada.

Testes de política e estabilização ficam em `Tests/TrioCoreTests/AutoMaximizePolicyTests.swift`. A persistência das duas listas de exceções usa uma suite temporária em `Tests/SettingsPersistenceTests.swift`; Finder é fixo nas exceções de encerramento, sem alterar as exceções da maximização. A validação de corridas com aplicativos reais deve usar as fixtures próprias do projeto, não documentos pessoais.
