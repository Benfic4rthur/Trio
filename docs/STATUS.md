# Estado do Trio

Atualizado em **20/11/2026**, horário de São Paulo. **Aplicativo gratuito e funcional: versão 0.2.0, build 12.** [Download Universal](https://raw.githubusercontent.com/Benfic4rthur/Trio/main/distribution/Trio-macOS-universal.zip) · [Instalação](INSTALLATION.md) · [Histórico](../CHANGELOG.md).

## Versão, distribuição e instalação

| Item | Estado verificado |
| --- | --- |
| Versão atual | **0.2.0, build 12**, instalada em `/Applications/Trio.app`. |
| Ambiente físico | macOS 27.2.1 (26B131), M1 Pro, Swift 6.4.2. |
| Arquiteturas | App e auxiliar Universal **arm64 + x86_64**, compilados e verificados localmente. Intel físico não testado. |
| Pacote | `Trio-macOS-universal.zip`. 1.954.998 bytes. Inclui o instalador, o guia e o app Universal. |
| Integridade do ZIP | SHA-256 `2cbace460392b0f2108d912ab6b7d99f9f717edcb5da8b58479984f011fe094a`; pacote, checksum e metadados atualizados juntos. |
| Distribuição | Repositório `Benfic4rthur/Trio` público, conforme alteração feita pelo proprietário. ZIP, checksum e metadados em `distribution/`; esse caminho não é uma GitHub Release. |
| Assinatura | Local, sem notarização Apple. O usuário não precisa de Xcode nem conta Apple Developer para usar o pacote pronto; Gatekeeper pode exigir a aprovação manual descrita no guia. |
| Instalador | `Install.command` confere identidade e assinatura, preserva a versão anterior e a quarentena, sem solicitar administrador ou desativar proteções. Recebeu revisão estática e `bash -n`; a atualização por esse script em outro Mac ainda precisa de ensaio. |
| Compilação e envios | Locais; código e distribuição enviados por MCP do GitHub. Sem Actions, tarefas de IA no GitHub ou builds remotos. |

## Fechamento e tamanho de janelas na build 12

Foram usados cinco IDs distintos num aplicativo de teste AppKit, com uma janela minimizada e uma janela que disponibilizava somente fechar. Os quatro primeiros fechamentos preservaram o processo e as janelas esperadas. O último encerrou o aplicativo. Uma segunda rodada fez o aplicativo recusar o encerramento normal. O encerramento forçado passou na versão instalada e o Trio continuou em execução. [Resultados por janela](validation/0.2.0-build12/closing.json).

O primeiro ensaio identificou superfícies que o WindowServer guardava depois de fechar a janela. A versão publicada usa o inventário de janelas acessíveis do aplicativo e verifica as janelas visíveis antes de encerrar. O teste de persistência usou preferências isoladas. Os 49 testes do núcleo passaram. A matriz de tamanhos inclui o monitor do ensaio e duas resoluções simuladas. [Critérios de tamanho](AUTO_MAXIMIZE.md).

## Compatibilidade do Claude — build 11

O diagnóstico confirmou que o Trio estava rodando, autorizado e habilitado. A recusa vinha de um elemento AX de 1×0 pt fora da reserva dos controles. A inspeção corrigida passou na janela real em 1,3×, com Edge e Codex preservados. O pacote Universal foi instalado com preferências e LoginItem mantidos. Os 25 testes existentes passaram. A captura automatizada do Claude introduz um indicador de compartilhamento que ocupa a região; não foi contada como confirmação visual do overlay. [Causa e limites](COMPATIBILITY-0.1.4.md).

## Cliques na barra — build 10

O clique parado mantém o painel; a ocultação começa no arrasto real. A versão instalada teve zero desaparecimentos nas 72 amostras de três cliques de barra, com pressão mantida e arrasto exercitados separadamente. Uma rodada adicional de ações passou na repetição, após falha isolada do vermelho na primeira tentativa. Os testes foram encerrados a pedido do usuário. [Evidências e limites](TITLEBAR-0.1.3.md).

## Retomada e alinhamento — build 9

O teste anterior mostrou um deslocamento nativo de 4 pt sem mudança da moldura: a build 8 permaneceu na linha antiga. A build 9 acompanhou a nova posição. Desenho após cinco hovers, três ciclos locais de notificações de sessão, dez cliques de conteúdo e os três botões na versão instalada passaram. O usuário confirmou o bloqueio/desbloqueio real em 15/11/2026. [Evidências e limites](RECOVERY-0.1.2.md).

## Funcionalidade e evidências

| Item | Estado e evidência |
| --- | --- |
| Testes | **25 testes passaram**, cobrindo geometria, limites, obstáculos, dimensões inválidas, coordenadas negativas, oclusão concêntrica e identidade de janelas coincidentes. |
| Janelas coincidentes | Build 8: **15 janelas com a mesma geometria e 16 trocas de foco passaram**, com painel alinhado e comprovação AX dos três controles. O critério não aceita apenas PID e bounds. |
| Cores e preferência | Cores explícitas em sRGB: vermelho `#FF5F57`, amarelo `#FFBC2E`, verde `#28C840`, sem branqueamento. A preferência existente de **1,3×** foi preservada; o padrão continua **1,5×**. |
| Região dos controles | Da borda esquerda até **5 pt após o verde original**; base concêntrica, com tamanho ajustado à área segura. Codex medido: 16 pt → 24 pt, **1,5×**. |
| Fundo | Círculos opacos cobrem os discos originais; área ao redor com 1,5% de opacidade, sem retângulo sólido. Estados de hover e barras diferentes precisam de revisão visual por aplicativo. |
| Vermelho + Smart Close | Build 8: com duas janelas coincidentes, o vermelho fechou somente o alvo (2→1) mantendo o processo vivo; na última janela, o Smart Close encerrou a fixture. Cliques HID reais nos controles Trio, com identidade AX/CG comprovada; Trio permaneceu vivo. A comparação anterior por `AXPress` teve comportamento diferente. [Detalhes](SMART-CLOSE.md). |
| Amarelo | Build 8: dois cliques minimizaram somente a janela alvo entre duas coincidentes, mantendo a outra normal e o processo vivo. A restauração AX da fixture entre cliques foi apenas preparação do teste. |
| Verde | Build 8: dois cliques no mesmo ID entre 15 janelas coincidentes restauraram a 900×620 e maximizaram na área útil, com frames CG/AX iguais, sem fullscreen ou amostras de painel visível desalinhado. |
| Arrasto e estabilidade | Rodada final da build 7: dez passos de arrasto e pausa pressionada; painel oculto durante movimento, sem amostras visíveis fora da âncora, alinhado novamente aos 150/300 ms após soltar. Três ativações e cliques no conteúdo mantiveram o painel acima da janela. |
| Menu e organização | Hover, saída para vermelho, saída do menu e organização em metades passaram na build 6. A rodada representativa da build 7 não repetiu amplamente todos esses caminhos. |
| Auto-maximização | Preferência implementada, com exceções por aplicativo. A janela inicial da fixture foi maximizada em ensaio; cobertura de alertas, diálogos e aplicativos diferentes segue na matriz de compatibilidade. |
| Início e instância | Registro por **SMAppService.loginItem** efetivamente abriu o Trio em modo acessório, sem configurações, com uma instância e Acessibilidade preservada. Migração remove o antigo agente próprio e respeita a preferência desligada. Logout/login completo ainda pendente. |
| Codex e Finder | Sobreposição observada. Indicadores de compartilhamento ou ferramentas ocupando a faixa podem levar à recusa segura sem solicitar novas permissões. |
| CPU e memória | Amostra de repouso de 10,001 s na build 8: **0,0007% de um núcleo**, **26,235 MiB de pegada física** e **95,297 MiB de RSS**. Uma amostra curta não mede picos ou vazamentos prolongados. [Método e limites](PERFORMANCE.md). |
| Identidade visual | ICNS instalado corresponde ao do projeto; símbolos ×, − e setas conferidos. [Prévia em tamanhos reais](branding/trio-icon-final.png). |

As evidências detalhadas em [PIPELINE-VALIDATION.md](PIPELINE-VALIDATION.md) identificam as builds e os processos de cada rodada. Resultados antigos não são atribuídos automaticamente a binários posteriores. O ensaio de identidade da build 8 foi restrito à fixture própria; dois cliques no verde restauraram e maximizaram a mesma janela entre as 15, com frames CG/AX iguais e sem fullscreen ou painel visível desalinhado. Esses resultados não certificam todos os aplicativos ou dispositivos de entrada.

## Cobertura ainda a ampliar

| Cenário | Situação |
| --- | --- |
| Barras padrão e personalizadas | Aplicativos reais adicionais e versões diferentes precisam entrar na matriz. |
| Smart Close com múltiplas janelas | A regra de primeira/última janela passou em duas janelas coincidentes da fixture na build 8; ampliar para mais aplicativos reais. |
| Monitores e Spaces | Monitores adicionais, transições de Spaces, Mission Control e Stage Manager ainda não têm cobertura física completa. |
| Início de sessão | O lançamento real pelo LoginItem passou; sair e entrar novamente na sessão ainda pendente. |
| Intel físico e macOS anterior | Não testados. macOS 13 é o destino mínimo de compilação, não uma certificação de todas as versões. |
| Instalação em outro Mac | Validar o pacote baixado, primeira abertura via Gatekeeper, renovação de Acessibilidade e rollback do instalador. |

## Limites de compatibilidade

O Trio atende à **janela ativa compatível**. O Trio pode ampliar apenas o vermelho. Identidade ambígua, ferramentas na área do vermelho ou informações de Acessibilidade insuficientes levam à preservação dos controles originais. A preferência de 5× é um limite solicitado e pode ser reduzida pelo espaço; não foi validada como tamanho efetivo em janelas comuns.

As APIs são públicas. O aplicativo não injeta código, altera os botões internos de outros processos nem desativa proteções do macOS. Na build 12, o vermelho fecha a janela pelo controle acessível e só pede o encerramento automático depois de confirmar a última janela e consultar as exceções. Se a instância ainda estiver rodando após cinco segundos, o Trio reconfirma que ela segue sem janelas antes de forçar o encerramento.
