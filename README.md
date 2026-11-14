![Trio — Controles maiores. Janelas mais fáceis.](Resources/GitHubBanner.svg)

<p align="center"><strong>Aplicativo gratuito para macOS · versão 0.1.0 · build 7</strong><br>Swift · AppKit · Apple Silicon e Intel</p>

<img align="right" src="Resources/TrioIcon.png" width="104" alt="Ícone do Trio">

O Trio amplia os controles de fechar, minimizar e maximizar na região original da janela. Os botões ficam mais fáceis de enxergar e alcançar, com uma onda de ampliação ao passar o mouse.

**[Baixar Trio para macOS](https://raw.githubusercontent.com/Benfic4rthur/Trio/main/distribution/Trio-macOS-universal.zip)** · [Instalação passo a passo](docs/INSTALLATION.md) · [Histórico e novidades](CHANGELOG.md)

O aplicativo pronto não exige Xcode nem uma conta Apple Developer do usuário. O pacote Universal inclui Apple Silicon e Intel. A versão atual tem assinatura local e não é notarizada pela Apple; a primeira abertura pode exigir aprovação manual do macOS.

## Instalação

1. **Baixe e extraia o ZIP.** Abra a pasta `Trio-macOS-universal`, que contém `Trio.app`, `Install.command` e o guia de instalação.
2. **Execute `Install.command`.** Ele verifica o app, copia somente o Trio para Aplicativos e preserva a versão anterior. Se estiver atualizando, use **Encerrar Trio** antes de instalar.
3. **Abra o Trio.** Se o macOS avisar que não pode verificar o desenvolvedor, e você confiar na origem, use **Ajustes do Sistema → Privacidade e Segurança → Abrir Mesmo Assim**. Interrompa se houver alerta de malware ou arquivo danificado.
4. **Permita Acessibilidade** para o Trio nas configurações. Depois, use **Esconder Trio** para manter os controles funcionando sem a janela de ajustes.

O instalador não pede administrador, não remove a quarentena nem desativa proteções. Se `/Applications` não permitir escrita, ele usa `~/Applications` e informa o caminho. Também é possível arrastar `Trio.app` para Aplicativos pelo Finder. [Guia completo em português, inglês e espanhol](docs/INSTALLATION.md).

## Controles de janela

| Controle | O que faz |
| --- | --- |
| Vermelho | Encaminha o clique ao botão original, preservando a integração testada com Smart Close. |
| Amarelo | Minimiza pelo controle original. |
| Verde | Maximiza dentro da área útil do monitor, sem tela cheia; outro clique restaura a geometria anterior. |
| Mouse sobre o verde | Abre opções para maximizar, organizar em metades ou centralizar. |
| Botão direito | Abre o menu com **Abrir Trio**, sem executar uma ação da janela. |

Fechar e minimizar exigem clique. O tamanho solicitado pode ser configurado entre **1× e 5×**, com ajuste ao espaço disponível. A preferência inicial é **1,5×**; no Codex medido, os controles de 16 pontos passam a 24 pontos. A área termina até cinco pontos depois do verde original, preservando ferramentas próximas.

Os círculos em repouso ficam nos centros dos controles originais e cobrem os botões pequenos. A área ao redor é quase transparente. Durante movimento que não possa ser acompanhado com segurança, o Trio oculta os controles e os reapresenta após confirmar a posição.

## Silencioso durante o uso

O Trio pode iniciar com a sessão sem abrir as configurações. Abrir o app manualmente mostra os ajustes da instância existente. **Esconder Trio** mantém o auxiliar ativo; **Encerrar Trio** termina o aplicativo.

Dock e barra de menus vêm desativados para o uso em segundo plano e podem ser habilitados nas configurações. Também é possível abrir os ajustes pelo botão direito na área dos controles.

**Abrir novas janelas maximizadas** é uma preferência opcional, com lista de exceções por aplicativo. Alertas e janelas que não permitem redimensionamento recebem tratamento conservador.

## Versão atual e últimas mudanças

| Versão | Build | Data | Destaques |
| --- | --- | --- | --- |
| **0.1.0** | **7** | **14/11/2026** | Controles ampliados, onda de hover, menu de organização, Smart Close, exceções de maximização automática e início silencioso. |

A build 7 corrigiu o rastro dos controles durante arrasto e animação: o painel fica oculto enquanto a posição não está confirmada e retorna alinhado. O auxiliar de início passou a ter bundle próprio e registro por `SMAppService.loginItem`. [Histórico completo](CHANGELOG.md).

O ZIP em [`distribution/`](distribution/) é o pacote real compilado localmente, com [checksum SHA-256](https://raw.githubusercontent.com/Benfic4rthur/Trio/main/distribution/Trio-macOS-universal.zip.sha256) e [metadados de versão](distribution/release.json). É uma distribuição pública pelo repositório; não é uma GitHub Release. O código-fonte é público e não usa GitHub Actions ou builds remotos.

## Validação e compatibilidade

- **17 testes de geometria passaram.** Incluem limites de espaço, obstáculos, dimensões inválidas, coordenadas negativas e cobertura concêntrica dos controles originais.
- **Build 7 instalada e exercitada** em macOS 27.2.1, M1 Pro. O pacote e o auxiliar contêm arm64 e x86_64; hardware Intel ainda não foi testado.
- **Smart Close 0.4.2:** o clique real no controle Trio chegou ao botão original e encerrou a fixture. `AXPress` direto teve comportamento diferente, mantendo o processo vivo. [Ensaio documentado](docs/SMART-CLOSE.md).
- **Verde e amarelo:** maximização sem tela cheia, restauração exata e minimização passaram pela sobreposição. A rodada final mediu arrasto, cliques no conteúdo e animação sem amostras visíveis desalinhadas. [Resultados e escopo](docs/PIPELINE-VALIDATION.md).
- **Início silencioso:** o registro por LoginItem abriu a instância do Trio sem configurações, em modo acessório, preservando a autorização de Acessibilidade. Uma sessão completa de sair/entrar no macOS ainda não foi exercitada.
- A sobreposição foi observada no **Codex** e no **Finder**. Regiões ocupadas por indicadores de compartilhamento ou ferramentas próximas podem ser recusadas.

A cobertura atende à **janela ativa compatível**. APIs públicas não permitem alterar os controles nativos de todos os aplicativos; o Trio usa uma sobreposição própria, sem injeção de código. Barras personalizadas e informações AX incompletas podem limitar a cobertura. Monitores adicionais, Spaces, hardware Intel e outras versões do macOS continuam na matriz de testes. O destino mínimo de compilação é macOS 13; isso não equivale a teste físico em todas essas versões.

## Compilar localmente

Para desenvolver, use Xcode com as ferramentas de desenvolvimento selecionadas:

```sh
./scripts/build-app.sh
./scripts/package-release.sh
```

O primeiro script compila o app e o auxiliar para arm64 e x86_64 e verifica a assinatura local. O segundo cria o ZIP, o checksum e os metadados. A assinatura padrão é ad-hoc; `TRIO_SIGN_IDENTITY` seleciona um certificado local. Um certificado local não transforma o pacote em software notarizado.

| Material | Conteúdo |
| --- | --- |
| [Instalação](docs/INSTALLATION.md) | Passos para o usuário e aprovação normal do macOS, em PT/EN/ES. |
| [Histórico](CHANGELOG.md) | Versões e últimas mudanças. |
| [Estado e limites](docs/STATUS.md) | O que foi verificado e o que continua pendente. |
| [APIs públicas](docs/API-RESEARCH.md) | Pesquisa técnica e limites das APIs. |
| [Smart Close](docs/SMART-CLOSE.md) | Interceptação e comparação dos caminhos de clique. |
| [Ensaios de execução](docs/PIPELINE-VALIDATION.md) | Resultados por build, sem extrapolar a cobertura. |
| [Ícone final](docs/branding/trio-icon-final.png) | Arte do app em 256, 128 e 64 pixels. |
