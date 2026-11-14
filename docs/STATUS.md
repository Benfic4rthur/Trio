# Estado do Trio

Atualizado em **14/11/2026**, horário de São Paulo. **Aplicativo gratuito e funcional: versão 0.1.1, build 8.** [Download Universal](https://raw.githubusercontent.com/Benfic4rthur/Trio/main/distribution/Trio-macOS-universal.zip) · [Instalação](INSTALLATION.md) · [Histórico](../CHANGELOG.md).

## Versão, distribuição e instalação

| Item | Estado verificado |
| --- | --- |
| Versão atual | **0.1.1, build 8**, instalada em `/Applications/Trio.app`. |
| Ambiente físico | macOS 27.2.1 (26B131), M1 Pro, Swift 6.4.2. |
| Arquiteturas | App e auxiliar Universal **arm64 + x86_64**, compilados e verificados localmente. Intel físico não testado. |
| Pacote | `Trio-macOS-universal.zip`, **1.848.889 bytes**, com instalador, guia 0.1.1 e app Universal; extração e assinatura conferidas localmente. |
| Integridade do ZIP | SHA-256 `e94b36feed23a6fb76e251bb4f50a95c15e00eb4401134d998310bb0ba90a5be`; pacote, checksum e metadados atualizados juntos. |
| Distribuição | Repositório `Benfic4rthur/Trio` público, conforme alteração feita pelo proprietário. ZIP, checksum e metadados em `distribution/`; esse caminho não é uma GitHub Release. |
| Assinatura | Local, sem notarização Apple. O usuário não precisa de Xcode nem conta Apple Developer para usar o pacote pronto; Gatekeeper pode exigir a aprovação manual descrita no guia. |
| Instalador | `Install.command` confere identidade e assinatura, preserva a versão anterior e a quarentena, sem solicitar administrador ou desativar proteções. Recebeu revisão estática e `bash -n`; a atualização por esse script em outro Mac ainda precisa de ensaio. |
| Compilação e envios | Locais; código e distribuição enviados por MCP do GitHub. Sem Actions, tarefas de IA no GitHub ou builds remotos. |

## Funcionalidade e evidências

| Item | Estado e evidência |
| --- | --- |
| Testes | **25 testes passaram**, cobrindo geometria, limites, obstáculos, dimensões inválidas, coordenadas negativas, oclusão concêntrica e identidade de janelas coincidentes. |
| Janelas coincidentes | Build 8: **15 janelas com a mesma geometria e 16 trocas de foco passaram**, com painel alinhado e comprovação AX dos três controles. O critério não aceita apenas PID e bounds. |
| Cores e preferência | Cores explícitas em sRGB: vermelho `#FF5F57`, amarelo `#FFBC2E`, verde `#28C840`, sem branqueamento. A preferência existente de **1,3×** foi preservada; o padrão continua **1,5×**. |
| Região dos controles | Da borda esquerda até **5 pt após o verde original**; base concêntrica, com tamanho ajustado à área segura. Codex medido: 16 pt → 24 pt, **1,5×**. |
| Fundo | Círculos opacos cobrem os discos originais; área ao redor com 1,5% de opacidade, sem retângulo sólido. Estados de hover e barras diferentes precisam de revisão visual por aplicativo. |
| Vermelho + Smart Close | Caminho real do NSButton Trio ao clique HID original passou na fixture, incluindo a build 7. A fixture encerrou e o Trio permaneceu ativo. `AXPress` direto não teve o mesmo resultado. [Detalhes](SMART-CLOSE.md). |
| Amarelo | Minimização passou pelo controle ampliado, com fixture viva. |
| Verde | Build 8: dois cliques no mesmo ID entre 15 janelas coincidentes restauraram a 900×620 e maximizaram na área útil, com frames CG/AX iguais, sem fullscreen ou amostras de painel visível desalinhado. |
| Arrasto e estabilidade | Rodada final da build 7: dez passos de arrasto e pausa pressionada; painel oculto durante movimento, sem amostras visíveis fora da âncora, alinhado novamente aos 150/300 ms após soltar. Três ativações e cliques no conteúdo mantiveram o painel acima da janela. |
| Menu e organização | Hover, saída para vermelho, saída do menu e organização em metades passaram na build 6. A rodada representativa da build 7 não repetiu amplamente todos esses caminhos. |
| Auto-maximização | Preferência implementada, com exceções por aplicativo. A janela inicial da fixture foi maximizada em ensaio; cobertura de alertas, diálogos e aplicativos diferentes segue na matriz de compatibilidade. |
| Início e instância | Registro por **SMAppService.loginItem** efetivamente abriu o Trio em modo acessório, sem configurações, com uma instância e Acessibilidade preservada. Migração remove o antigo agente próprio e respeita a preferência desligada. Logout/login completo ainda pendente. |
| Codex e Finder | Sobreposição observada. Indicadores de compartilhamento ou ferramentas ocupando a faixa podem levar à recusa segura sem solicitar novas permissões. |
| Identidade visual | ICNS instalado corresponde ao do projeto; símbolos ×, − e setas conferidos. [Prévia em tamanhos reais](branding/trio-icon-final.png). |

As evidências detalhadas em [PIPELINE-VALIDATION.md](PIPELINE-VALIDATION.md) identificam as builds e os processos de cada rodada. Resultados antigos não são atribuídos automaticamente a binários posteriores. O ensaio de identidade da build 8 foi restrito à fixture própria; dois cliques no verde restauraram e maximizaram a mesma janela entre as 15, com frames CG/AX iguais e sem fullscreen ou painel visível desalinhado. Esses resultados não certificam todos os aplicativos ou dispositivos de entrada.

## Cobertura ainda a ampliar

| Cenário | Situação |
| --- | --- |
| Barras padrão e personalizadas | Aplicativos reais adicionais e versões diferentes precisam entrar na matriz. |
| Smart Close com múltiplas janelas | Testar regras de primeira/última janela e mais aplicativos. |
| Monitores e Spaces | Monitores adicionais, transições de Spaces, Mission Control e Stage Manager ainda não têm cobertura física completa. |
| Início de sessão | O lançamento real pelo LoginItem passou; sair e entrar novamente na sessão ainda pendente. |
| Intel físico e macOS anterior | Não testados. macOS 13 é o destino mínimo de compilação, não uma certificação de todas as versões. |
| Instalação em outro Mac | Validar o pacote baixado, primeira abertura via Gatekeeper, renovação de Acessibilidade e rollback do instalador. |

## Limites de compatibilidade

O Trio atende à **janela ativa compatível**. Controles ausentes, identidade ambígua, ferramentas próximas ou informações de Acessibilidade incompletas levam à preservação dos controles originais. A preferência de 5× é um limite solicitado e pode ser reduzida pelo espaço; não foi validada como tamanho efetivo em janelas comuns.

As APIs são públicas. O aplicativo não injeta código, altera os botões internos de outros processos nem desativa proteções do macOS. O vermelho não usa encerramento direto ou fallback silencioso por AXPress para imitar o Smart Close.
