# Estado do protótipo

Atualizado em **14/11/2026**, horário de São Paulo. **Protótipo em validação**, sem release pública.

## Implementação e evidências

| Item | Estado e evidência |
| --- | --- |
| Pasta inicial | Vazia; nenhum arquivo anterior sobrescrito. |
| Ambiente | macOS 27.2.1 (26B131), Apple M1 Pro, Swift 6.4.2. |
| APIs públicas | Documentação Apple e headers do SDK consultados; [pesquisa registrada](API-RESEARCH.md). |
| Build instalada | `/Applications/Trio.app`, versão **0.1.0**, build **2**. O executável instalado contém **arm64 e x86_64**, verificado com `lipo`. Aplicativo e auxiliar têm build local Universal; Intel físico não testado. |
| Geometria | **17 testes passaram**: ajustes de tamanho, obstáculos, dimensões inválidas, coordenadas negativas, região reservada e cobertura concêntrica dos discos nativos. |
| Tamanho escolhido | Preferência inicial **1,5×**, configurável entre 1× e 5×. O tamanho efetivo depende do espaço da janela. |
| Região reservada | Da borda esquerda da janela até **5 pt após a borda direita do verde original**. Crescimento vertical simétrico à linha original, dentro da janela e sem obstáculos. A base mantém os centros nativos. |
| Controles originais e fundo | Círculos opacos concêntricos cobrem os discos originais em repouso. A área ao redor tem **1,5% de opacidade**; não há fundo retangular sólido. Geometria real do Codex: 16 pt → 24 pt, **1,5×**. Hover, sombras e barras personalizadas exigem conferência visual. |
| Smart Close instalado | 0.4.2 build 10, ativo durante os ensaios; fonte correspondente e imports investigados. Preferências preservadas. |
| Comparação A/B de clique | **Passou na fixture descartável:** `AXPress` fechou a janela sem terminar o processo; clique HID no botão original terminou o aplicativo. [Evidência e limites](SMART-CLOSE.md#validação-runtime-na-fixture-14112026). |
| Encaminhamento pelo Trio | **Passou em uma build anterior**, pela fixture e pelos controles ampliados: vermelho encerrou a fixture com Smart Close; amarelo minimizou; verde maximizou e restaurou. Há revalidação da janela e hit-test antes do HID. A repetição da build atual está em andamento. [Detalhes](SMART-CLOSE.md#validação-completa-pelo-botão-ampliado-trio). |
| Animação de janelas | Implementação curta e limitada para maximizar/restaurar, com cancelamento e respeito a **Reduzir Movimento**. Código integrado; ensaios de execução em andamento, sem resultado final declarado. |
| Configurações | AppKit; typecheck arm64 e x86_64; renderização offscreen sem cortes. Pausar, esconder e encerrar são ações distintas. |
| Presença e instância | Abertura manual, reabertura, lock de instância, início silencioso, Dock e menu opcionais implementados. A build atual está instalada. Login após uma sessão completa e matriz de esconder/reabrir/encerrar ainda pendentes. |
| Novas janelas maximizadas | Preferência implementada e ativada por padrão. O motor observa criação de janelas e preserva diálogos e janelas sem redimensionamento permitido; teste real pendente. |
| Codex e Finder | Sobreposição observada no Codex e em janela comum do Finder. A faixa ocupada por indicador de compartilhamento em outra janela do Finder levou à recusa segura, sem pedir novas permissões. Isso não estabelece cobertura geral desses aplicativos. |
| Identidade visual | Ícone PNG 1024, ICNS com ×, − e setas, template vetorial de menu e banner criados localmente. ICNS instalado e do projeto com SHA-256 idêntico; [prévia final em 256/128/64 px](branding/trio-icon-final.png). |
| Backup | Repositório privado; checkpoint `ae5f38c` salvo e conferido por MCP do GitHub. Novo checkpoint final aguarda os ensaios e ajustes atuais. Sem Actions, tarefas de IA no GitHub ou builds remotos. |

## Testes ainda necessários

| Cenário | Situação |
| --- | --- |
| Sobreposição no Codex | Geometria e presença já observadas; repetição de alinhamento, hover, cobertura dos originais e ferramentas próximas na build atual em andamento. |
| Barras padrão e personalizadas | Fixture disponível; matriz de compatibilidade real ainda pendente. |
| Vermelho ampliado + Smart Close | Ciclo completo passou na fixture em build anterior; repetir após as mudanças atuais. Múltiplas janelas e outros aplicativos ainda pendentes. |
| Clique direito | Confirmar que o menu abre sem fechar, minimizar ou maximizar. |
| Amarelo e verde | Minimizar, maximizar na área útil e restaurar passaram na fixture em build anterior. Repetir na build atual e conferir animação, término da geometria e cancelamento. |
| Novas janelas | Confirmar maximização apenas das janelas elegíveis, com exclusão de alertas e diálogos. |
| Movimento, resize e troca de foco | Confirmar que o painel acompanha ou desaparece sem permanecer sobre outra janela. |
| Monitores e Spaces | Pendente. Apenas um monitor conectado durante a inspeção inicial. |
| Sessão e reabertura | Validar login silencioso, abertura manual da instância existente e comportamento de esconder/encerrar. |
| Intel físico e versões anteriores | Não testados. O destino mínimo declarado é macOS 13. |

## Limites atuais

A cobertura inicial é a janela ativa. Janelas com controles ausentes, geometria ambígua ou ferramentas próximas sem área segura permanecem com os controles originais. A área quase transparente evita impor uma cor de barra ao aplicativo; os círculos opacos em repouso fazem a cobertura dos discos originais. Controles personalizados, sombras e estados de hover ainda exigem avaliação visual por aplicativo. O valor configurável de 5× é um limite solicitado, e não um tamanho real validado nas janelas comuns deste protótipo.

O Trio usa APIs públicas, sem injeção de código ou alteração de proteções do macOS. O botão vermelho encaminha um clique ao controle original; não usa encerramento direto para reproduzir as regras do Smart Close.

Downloads públicos e uma futura página no catálogo ALLM4 dependem dos próximos ensaios. Nenhum site ou release pública foi criado nesta etapa.
