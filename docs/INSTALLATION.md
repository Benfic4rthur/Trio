# Instalar o Trio

[Português](#português) · [English](#english) · [Español](#español)

Guia da versão **0.1.1, build 8**, preparado em 14/11/2026. **[Baixar Trio para macOS](https://raw.githubusercontent.com/Benfic4rthur/Trio/main/distribution/Trio-macOS-universal.zip)** · [Checksum SHA-256](https://raw.githubusercontent.com/Benfic4rthur/Trio/main/distribution/Trio-macOS-universal.zip.sha256) · [Histórico](../CHANGELOG.md).

O pacote e o código-fonte são públicos e gratuitos. O ZIP é distribuído pela pasta `distribution/` do repositório; esse caminho não é uma GitHub Release. Não é necessário compilar o app para instalá-lo.

## Português

### O que você precisa

O aplicativo pronto não exige Xcode nem uma conta Apple Developer do usuário. O bundle Universal contém Apple Silicon e Intel. O destino de compilação é macOS 13 ou posterior; o teste físico atual foi feito em macOS 27.2.1, em um M1 Pro. Intel físico e versões anteriores ainda não foram testados.

A build atual tem assinatura local, sem notarização Apple. Uma assinatura ad-hoc verifica a integridade do código, mas não autentica o autor. Um certificado Apple Development local também não equivale a Developer ID ou notarização. A Apple exige o certificado apropriado para o fluxo de notarização. [Assinatura ad-hoc](https://developer.apple.com/documentation/security/seccodesignatureflags/adhoc), [requisitos de notarização](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

### Instalar o pacote extraído

1. Extraia o ZIP no Finder. A pasta `Trio-macOS-universal` deve conter `Trio.app` e `Install.command` lado a lado. Se o Trio já estiver aberto, use **Encerrar Trio** nas configurações antes de atualizar.
2. Execute `Install.command` nessa pasta. Também é possível abrir o Terminal e usar o comando abaixo, depois de conferir a origem e o conteúdo do script:

   ```sh
   cd "$HOME/Downloads/Trio-macOS-universal"
   /bin/bash ./Install.command
   ```

3. O script confere o identificador `com.allm4.Trio`, o executável e a assinatura; copia apenas esse bundle para `/Applications/Trio.app`. Se essa pasta não permitir escrita sem administrador, usa `~/Applications/Trio.app` e informa o caminho. Não pede senha de administrador nem baixa componentes.
4. Se houver uma versão anterior do mesmo Trio, ela fica preservada em `.Trio-backups` dentro da pasta Aplicativos escolhida. O caminho exato aparece no Terminal. A instalação usa uma cópia temporária verificada antes de substituir a anterior.

O instalador preserva os atributos e a quarentena do download. Não altera o Gatekeeper, as permissões de outros apps ou a assinatura do pacote. A verificação local da assinatura não substitui conhecer a origem do arquivo.

**Alternativa manual:** arraste `Trio.app` para Aplicativos pelo Finder, preservando uma cópia da versão anterior se for uma atualização. Abra o app pela pasta de destino.

### Primeira abertura e Acessibilidade

Tente abrir o Trio. Se houver aviso de desenvolvedor não identificado, e você confiar na origem, vá a **Ajustes do Sistema → Privacidade e Segurança → Abrir Mesmo Assim** e confirme **Abrir**. Se houver alerta de malware ou arquivo danificado, interrompa e obtenha outra cópia. [Orientação da Apple](https://support.apple.com/en-us/102445).

Nas configurações do Trio, use **Permitir Acessibilidade** e habilite **Trio** em **Privacidade e Segurança → Acessibilidade**. Se necessário, adicione o app instalado pelo botão **+**. [Permissões de Acessibilidade da Apple](https://support.apple.com/en-ie/guide/mac-help/mh43185/27/mac/27).

O Trio não precisa de Gravação de Tela para descobrir a geometria das janelas. A preferência **Iniciar com a sessão** depende da aprovação normal do macOS para itens de início; o teste após uma sessão completa ainda está pendente. Uma atualização com assinatura local diferente pode exigir nova autorização de Acessibilidade. [Identidade de código entre versões](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

Depois de configurar, **Esconder Trio** mantém o auxiliar funcionando. Abra `Trio.app` novamente para voltar às configurações. **Encerrar Trio** é uma ação separada.

## English

### Requirements and installation

The prebuilt app needs neither Xcode nor an Apple Developer account from its user. The Universal bundle includes Apple Silicon and Intel. Its deployment target is macOS 13; physical testing currently covers macOS 27.2.1 on an M1 Pro. Intel hardware and earlier macOS versions remain untested.

This build is locally signed and **not notarized by Apple**. Ad-hoc signing does not identify its author, and a local Apple Development certificate does not replace Developer ID notarization. [Apple signing information](https://developer.apple.com/documentation/security/seccodesignatureflags/adhoc), [notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

1. Extract the ZIP. Keep `Trio.app` and `Install.command` together inside `Trio-macOS-universal`. Quit an existing Trio through its settings before updating.
2. Run `Install.command`, or review the script and run the same Terminal command shown in the Portuguese section. Adjust the folder path if needed.
3. The installer validates the bundle identifier and signature, then copies only Trio to `/Applications`. If that location requires administrator access, it uses `~/Applications`. It preserves a previous Trio in a hidden `.Trio-backups` folder and prints its location.

The installer preserves quarantine and other metadata. It does not disable macOS protections, change other apps, request administrator privileges, or download software. You can instead drag `Trio.app` into Applications using Finder and keep a backup of an older copy.

### First launch

Try opening Trio. For an unidentified-developer warning, use **System Settings → Privacy & Security → Open Anyway**, then **Open**, only if you trust the source. Stop if macOS reports malware or a damaged file. [Apple’s opening instructions](https://support.apple.com/en-us/102445).

Use Trio’s Accessibility button, then enable **Trio** under **Privacy & Security → Accessibility**. Add the installed app with **+** if missing. [Apple’s Accessibility instructions](https://support.apple.com/en-ie/guide/mac-help/mh43185/27/mac/27).

Screen Recording is not needed for window geometry. Launch at login uses the system’s normal approval; a full login-session test is still pending. A locally signed update may need renewed Accessibility permission. [Code identity across updates](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

**Hide Trio** keeps the helper running. Open the installed app again to access settings; **Quit Trio** stops it.

## Español

### Requisitos e instalación

La aplicación compilada no requiere Xcode ni una cuenta Apple Developer del usuario. El bundle Universal incluye Apple Silicon e Intel. El destino de compilación es macOS 13; las pruebas físicas actuales corresponden a macOS 27.2.1 en un M1 Pro. Intel físico y versiones anteriores siguen pendientes.

Esta build tiene firma local y **no está certificada ante notario por Apple**. La firma ad-hoc no identifica al autor; un certificado Apple Development local tampoco sustituye la certificación con Developer ID. [Firma ad-hoc de Apple](https://developer.apple.com/documentation/security/seccodesignatureflags/adhoc), [requisitos de certificación](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

1. Extrae el ZIP y mantén `Trio.app` e `Install.command` juntos en `Trio-macOS-universal`. Cierra Trio desde su configuración antes de actualizar.
2. Ejecuta `Install.command` o revisa el script y usa el comando de Terminal mostrado en la sección en portugués, ajustando la ruta si hace falta.
3. El instalador verifica el identificador y la firma y copia únicamente Trio a `/Applications`. Si requiere acceso de administrador, utiliza `~/Applications`. Conserva la versión anterior en `.Trio-backups` y muestra su ruta.

El instalador conserva la cuarentena y los metadatos. No desactiva protecciones, modifica otras apps, solicita privilegios de administrador ni descarga componentes. También puedes arrastrar `Trio.app` a Aplicaciones con Finder y conservar una copia de la versión anterior.

### Primera apertura

Intenta abrir Trio. Ante un aviso de desarrollador no identificado, y solo si confías en la fuente, ve a **Ajustes del Sistema → Privacidad y seguridad → Abrir igualmente** y confirma **Abrir**. Detente si macOS indica malware o un archivo dañado. [Instrucciones de Apple](https://support.apple.com/es-es/102445).

Desde Trio, abre los permisos de accesibilidad y activa **Trio** en **Privacidad y seguridad → Accesibilidad**. Usa **+** si falta la app instalada. [Permisos de accesibilidad de Apple](https://support.apple.com/en-ie/guide/mac-help/mh43185/27/mac/27).

No se necesita Grabación de Pantalla para obtener la geometría. El inicio de sesión requiere la aprobación normal del sistema; la prueba de una sesión completa sigue pendiente. Una actualización con otra firma local puede requerir una nueva autorización de accesibilidad. [Identidad del código entre versiones](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

**Ocultar Trio** mantiene activo el auxiliar. Abre la app instalada para volver a la configuración; **Salir de Trio** lo termina.

## Distribuição e metadados do site

O proprietário tornou `Benfic4rthur/Trio` público. O pacote real da versão atual fica em `distribution/`, com URL raw acessível sem autenticação, checksum e `release.json`. O site não inclui tokens nem depende da sessão GitHub do visitante.

A consulta do site tenta uma GitHub Release válida; se não houver uma, usa os metadados públicos de `distribution/`. Como última alternativa, a prévia do site inclui o mesmo ZIP real e seus metadados, conferidos durante o build. Falha de rede não deve inventar uma versão nem uma publicação em Releases.

O endereço estável de `distribution/` aponta para a versão atual e deve ser atualizado junto com o pacote e o checksum. Uma futura GitHub Release pode usar a URL `latest` depois de seus arquivos serem publicados e conferidos. O histórico identifica as versões, sem simular releases anteriores.

Os metadados registram versão, build, arquiteturas, destino mínimo, assinatura local, `notarized: false`, URL pública do ZIP e checksum. `publicRelease: false` distingue essa distribuição de uma GitHub Release. Isso não indica que o download seja privado. Não anunciar aprovação Apple ou compatibilidade universal.

Estrutura esperada do ZIP:

```text
Trio-macOS-universal/
  Trio.app/
  Install.command
  INSTALLATION.md
```

Publicar também um checksum SHA-256 do ZIP em um arquivo separado. O pacote pronto não contém Xcode, SwiftPM ou uma etapa de build remota. O pacote é criado localmente, com assinatura e checksum verificados. A execução do instalador em outro Mac, incluindo a primeira aprovação do Gatekeeper, ainda precisa de ensaio.

## Validação deste material

O script recebeu revisão estática e verificação de sintaxe com `/bin/bash -n`. **Não foi executado para instalar, substituir ou encerrar o Trio durante essa preparação**, preservando o aplicativo em uso. Cópia, preservação da versão anterior, rollback e primeira abertura em outro Mac com Gatekeeper ativo permanecem na matriz de testes; a revisão estática não comprova esses caminhos em outro computador.
