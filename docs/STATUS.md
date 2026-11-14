# Estado do protótipo

Atualizado em **14/11/2026**, horário de São Paulo. **Protótipo em validação**, sem release pública.

## Implementação e evidências

| Item | Estado e evidência |
| --- | --- |
| Pasta inicial | Vazia; nenhum arquivo anterior sobrescrito. |
| Ambiente | macOS 27.2.1 (26B131), Apple M1 Pro, Swift 6.4.2. |
| APIs públicas | Documentação Apple e headers do SDK consultados; [pesquisa registrada](API-RESEARCH.md). |
| Arquiteturas | Projeto e script de build Universal arm64 + x86_64. Componentes da interface com typecheck nas duas arquiteturas; compilação integrada em andamento. Intel físico não testado. |
| Geometria | **16 testes passaram**: ajustes de tamanho, obstáculos, máscara dos originais, coordenadas negativas e região reservada. |
| Tamanho escolhido | Preferência inicial **1,5×**, configurável entre 1× e 5×. O tamanho efetivo depende do espaço da janela. |
| Região reservada | Da borda esquerda da janela até **5 pt após a borda direita do verde original**. Crescimento vertical simétrico à linha original, dentro da janela e sem obstáculos. |
| Controles originais | Máscara geométrica implementada para ocultar os três botões pequenos; aparência da máscara em barras reais ainda pendente. |
| Smart Close instalado | 0.4.2 build 10, ativo durante os ensaios; fonte correspondente e imports investigados. Preferências preservadas. |
| Comparação A/B de clique | **Passou na fixture descartável:** `AXPress` fechou a janela sem terminar o processo; clique HID no botão original terminou o aplicativo. [Evidência e limites](SMART-CLOSE.md#validação-runtime-na-fixture-14112026). |
| Encaminhamento pelo Trio | Implementado: ocultação do painel, revalidação da janela e hit-test antes do par de eventos HID. Ensaio completo iniciado no controle ampliado ainda pendente. |
| Configurações | AppKit; typecheck arm64 e x86_64; renderização offscreen sem cortes. Pausar, esconder e encerrar são ações distintas. |
| Presença e instância | Lifecycle implementado: abertura manual, reabertura, lock de instância, início silencioso, Dock e menu opcionais. Teste integrado pendente. |
| Novas janelas maximizadas | Preferência implementada e ativada por padrão. O motor observa criação de janelas e preserva diálogos e janelas sem redimensionamento permitido; teste real pendente. |
| Identidade visual | Ícone PNG 1024, ICNS, template vetorial de menu e banner do repositório criados localmente e inspecionados. |
| Backup | Repositório privado; envios por MCP do GitHub. Sem Actions, tarefas de IA no GitHub ou builds remotos. |

## Testes ainda necessários

| Cenário | Situação |
| --- | --- |
| Sobreposição no Codex | Alinhamento, máscara, hover, área de clique e ferramentas próximas ainda a validar em execução. |
| Barras padrão e personalizadas | Fixture disponível; matriz de compatibilidade real ainda pendente. |
| Vermelho ampliado + Smart Close | Falta confirmar o ciclo completo de ocultar painel, clicar no original e acompanhar o encerramento. O A/B direto não substitui esse ensaio. |
| Clique direito | Confirmar que o menu abre sem fechar, minimizar ou maximizar. |
| Amarelo e verde | Validar minimizar, maximizar na área útil e restaurar por meio do controle ampliado. |
| Novas janelas | Confirmar maximização apenas das janelas elegíveis, com exclusão de alertas e diálogos. |
| Movimento, resize e troca de foco | Confirmar que o painel acompanha ou desaparece sem permanecer sobre outra janela. |
| Monitores e Spaces | Pendente. Apenas um monitor conectado durante a inspeção inicial. |
| Sessão e reabertura | Validar login silencioso, abertura manual da instância existente e comportamento de esconder/encerrar. |
| Intel físico e versões anteriores | Não testados. O destino mínimo declarado é macOS 13. |

## Limites atuais

A cobertura inicial é a janela ativa. Janelas com controles ausentes, geometria ambígua ou ferramentas próximas sem área segura permanecem com os controles originais. A máscara opaca pode não reproduzir o material e a cor de barras próprias; esse ponto exige avaliação visual por aplicativo.

O Trio usa APIs públicas, sem injeção de código ou alteração de proteções do macOS. O botão vermelho encaminha um clique ao controle original; não usa encerramento direto para reproduzir as regras do Smart Close.

Downloads públicos e uma futura página no catálogo ALLM4 dependem dos próximos ensaios. Nenhum site ou release pública foi criado nesta etapa.
