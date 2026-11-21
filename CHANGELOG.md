# Histórico do Trio

## 0.2.2 — build 14 · 20/11/2026

- Depois de confirmar que a última janela fechou, o Trio usa `forceTerminate` diretamente na mesma instância do aplicativo, sem pedir um encerramento normal antes.
- Outras janelas, inclusive minimizadas, impedem a saída. O Finder e as exceções escolhidas pelo usuário continuam protegidos; uma identidade ou contagem incerta não autoriza encerrar outro processo.
- Corrige o acompanhamento do fechar nativo no Edge e no Antigravity quando o evento chega antes de a janela desaparecer dos inventários. A verificação aguarda a confirmação por tentativas limitadas, sem condicionar a regra ao número da versão desses aplicativos.
- Forçar a saída pode interromper tarefas em segundo plano e perder dados ainda não salvos. Aplicativos que precisam continuar trabalhando sem janelas devem ser adicionados às exceções.

**Validação:** consulte o [estado da versão](docs/STATUS.md) para os resultados da build 14. Os ensaios das versões anteriores permanecem identificados abaixo.

## 0.2.1 — build 13 · 20/11/2026

- O Trio pede o encerramento assim que confirma que a última janela fechou. Se a mesma instância permanecer sem janelas na verificação seguinte, força sua saída. O intervalo fixo de cinco segundos foi removido.
- No Microsoft Edge, o Trio também acompanha a destruição da última janela principal identificada quando o navegador recebe o fechamento diretamente.
- A verificação da saída acompanha a atualização da Acessibilidade e da animação do macOS. Abrir outra janela cancela o encerramento pendente. O Finder e os aplicativos configurados como exceções continuam protegidos.

## 0.2.0 — build 12 · 20/11/2026

- O vermelho aciona o fechar da janela selecionada. Quando ela é a última e o fechamento foi confirmado, o Trio pede ao aplicativo que encerre. Se a mesma instância ainda estiver rodando cinco segundos depois, o Trio pode forçar o encerramento após reconfirmar que ela segue sem janelas. Outras janelas abertas e minimizadas são preservadas.
- Nova lista de aplicativos que devem continuar abertos após fechar a última janela. O Finder vem incluído. O pedido explícito de encerrar todas as janelas fica no menu do Trio.
- Janelas com apenas o botão de fechar também podem receber o Trio. Se faltar espaço, o Trio pode apresentar só o vermelho e preservar as ferramentas vizinhas.
- A maximização automática considera o tamanho inicial em pontos e a proporção da área útil do monitor. Janelas pequenas, folhas e diálogos conservam suas dimensões.

## 0.1.4 — build 11 · 18/11/2026

- Corrige a recusa de janelas, como a do Claude, quando a árvore AX contém elementos vazios fora da região reservada aos controles.
- Preserva a exigência de geometria positiva para janelas, botões e ações; não ignora elementos desconhecidos ou obstáculos dentro da reserva.
- Mantém o tamanho salvo, início silencioso, encaminhamento para Smart Close e funcionamento por notificações.

**Validação:** causa reproduzida por diagnóstico estrutural na janela real do Claude, inspeção corrigida em 1,3×, layouts de Edge/Codex preservados e 25 testes existentes passaram. Universal arm64/x86_64 compilado localmente; Intel físico e confirmação visual do overlay no Claude permanecem fora deste ensaio. [Evidências e limites](docs/COMPATIBILITY-0.1.4.md).

## 0.1.3 — build 10 · 15/11/2026

- Mantém o Trio visível ao clicar na barra sem mover a janela.
- O pressionamento arma a detecção; a ocultação temporária começa ao arrastar, a partir de 2 pontos de deslocamento.
- Limpa a intenção de arrasto ao soltar, ocultar ou trocar de contexto, preservando as verificações de identidade.
- Mantém preferências salvas e a correção de retomada da sessão da 0.1.2.

**Validação:** reprodução anterior e ensaio da versão instalada com três cliques na barra, pressão mantida e arrasto real; 25 testes existentes passaram. A rodada de ações passou na repetição, após uma primeira tentativa em que o vermelho não fechou a fixture. [Evidências e limites](docs/TITLEBAR-0.1.3.md).

## 0.1.2 — build 9 · 15/11/2026

- Corrige o alinhamento quando os botões nativos mudam de posição sem redimensionar a janela.
- Limpa os pixels anteriores da camada transparente antes de redesenhar a onda.
- Reconstrói o painel e as observações de Acessibilidade ao retomar a sessão, preservando o tamanho escolhido e a geometria de restauração.
- Usa notificações públicas e tentativas limitadas, com uma recuperação pelo primeiro movimento do ponteiro quando necessário. Sem varredura contínua.
- Evita recriar o painel em cliques normais que não mudam sua geometria; notificações de layout de conteúdo são agrupadas.

**Validação:** 25 testes existentes, teste de desenho, reprodução da falha anterior por deslocamento de 4 pontos, três ciclos locais de notificações da sessão, dez cliques no conteúdo sem desaparecimento e verde/amarelo/vermelho reais no aplicativo instalado. O usuário confirmou o bloqueio e desbloqueio físicos. [Detalhes](docs/RECOVERY-0.1.2.md).

## 0.1.1 — build 8 · 14/11/2026

| Área | Mudança |
| --- | --- |
| Janelas coincidentes | Corrige a recusa de várias janelas do mesmo aplicativo com bounds idênticos. A seleção exige comprovação pública AX dos três controles da janela ativa; PID e geometria sozinhos não bastam. |
| Troca de foco | Verifica novamente a identidade e a posição antes de apresentar controles ou encaminhar ações, preservando a recusa de alvos ambíguos. |
| Cores | Vermelho `#FF5F57`, amarelo `#FFBC2E` e verde `#28C840` em sRGB explícito, sem o branqueamento de iterações anteriores. |
| Preferências | A atualização preserva o tamanho já salvo. O padrão de uma instalação nova continua sendo 1,5×. |

**Validação da build 8:** 25 testes passaram. O ensaio com 15 janelas coincidentes e 16 trocas de foco verificou alinhamento e identidade AX dos três botões. Dois cliques no verde restauraram e maximizaram a mesma janela entre as 15, com frames CG/AX iguais, sem fullscreen nem painel visível desalinhado. Em duas janelas coincidentes, o amarelo minimizou somente o alvo em dois cliques; o vermelho fechou a primeira janela mantendo o processo e encerrou a fixture pelo Smart Close ao fechar a última. [Ensaios de execução](docs/PIPELINE-VALIDATION.md) mantém os resultados de cada build separados.

## 0.1.0 — build 7 · 14/11/2026

Aplicativo gratuito para macOS, com pacote Universal para Apple Silicon e Intel. [Baixar a versão atual](https://raw.githubusercontent.com/Benfic4rthur/Trio/main/distribution/Trio-macOS-universal.zip) · [Instalação PT/EN/ES](docs/INSTALLATION.md).

| Área | Novidade |
| --- | --- |
| Controles | Fechar, minimizar e maximizar ampliados na região original, com áreas de clique maiores e tamanho adaptado ao espaço. |
| Aparência | Círculos concêntricos cobrem os originais; fundo quase transparente e ampliação em onda no hover. |
| Verde | Maximização na área útil sem fullscreen, restauração da geometria anterior e menu de organização em metades/centro. |
| Smart Close | Vermelho encaminha o clique original, preservando a integração exercitada com Smart Close 0.4.2. |
| Movimento | Painel oculto durante arrasto e interpolação insegura, com reapresentação após confirmar o alinhamento. |
| Sessão | Auxiliar com bundle próprio e registro por LoginItem, início silencioso e proteção contra instâncias duplicadas. |
| Preferências | Pausar, esconder e encerrar separados; Dock/menu opcionais; auto-maximização de novas janelas e exceções por aplicativo. |
| Instalação | ZIP real com `Install.command`, guia em três idiomas, checksum e metadados de versão. |

**Validação:** 17 testes de geometria passaram. A build 7 foi exercitada no M1 Pro com macOS 27.2.1 para arrasto, estabilidade, minimizar, maximizar/restaurar e vermelho integrado ao Smart Close. O lançamento real pelo LoginItem também passou. [Escopo e pendências](docs/STATUS.md).

O destino mínimo de compilação é macOS 13. Hardware Intel, monitores adicionais, cobertura completa de Spaces e instalação em outro Mac permanecem pendentes. O pacote usa assinatura local e não é notarizado pela Apple.

### Iterações anteriores da 0.1.0

| Builds | Trabalho realizado |
| --- | --- |
| 1–2 | Base AppKit, geometria conservadora, configurações, ações de janela e identidade visual. |
| 3–4 | Painel flutuante, ensaios de ordem de janelas, animação e identificação de atrasos durante movimento. |
| 5–6 | Auxiliar em bundle separado, migração para LoginItem e ensaios de hover, organização e encaminhamento dos cliques. |
| **7** | Ocultação antecipada no arrasto, reapresentação alinhada e regressão representativa da primeira versão pública. |

As builds 1–6 foram iterações internas da mesma versão, não releases públicas anteriores.
