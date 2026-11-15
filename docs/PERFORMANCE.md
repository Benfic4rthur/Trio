# Consumo do Trio

## 0.1.2 — build 9 · 15/11/2026

Após os testes, uma amostra de repouso de 10,004 s mediu CPU média de 0,0000% de um núcleo na precisão impressa, pegada física de 24,688 MiB e RSS de 92,062 MiB, sem alteração da pegada ou despertares no intervalo. Isso descreve essa amostra curta no M1 Pro; não mede picos ou vazamentos prolongados. A medição usa o mesmo utilitário e conversão Mach descritos abaixo.

## 0.1.1 — build 8

Medição local em 14/11/2026, no M1 Pro com macOS 27.2.1. App instalado em `/Applications/Trio.app`, controles em 1,3×, início automático ativo e configurações escondidas.

Após o ensaio de quinze janelas coincidentes e duas ações de maximizar/restaurar, a fixture permaneceu aberta com quinze janelas, oculta e ociosa. Nenhum ensaio de interação foi executado durante esta amostra.

| Medida | Resultado |
| --- | --- |
| Intervalo | 10,001 segundos |
| CPU média, em proporção a um núcleo | 0,0007% |
| Pegada física (`ri_phys_footprint`) | 26,235 MiB |
| Memória residente (`ri_resident_size`) | 95,297 MiB |
| Variação da pegada física no intervalo | −0,016 MiB |
| Despertares de pacote ocioso | 0 |
| Despertares por interrupção | 1 |

A memória residente inclui mapeamentos compartilhados; ela não equivale à memória privada atribuída somente ao Trio. A pegada física e o RSS são apresentados separadamente para não confundir as métricas. Uma amostra curta em repouso não representa picos de CPU durante animação nem garante o mesmo consumo em todos os Macs.

No ensaio de quantidade de janelas, o RSS informado pelo `ps` passou de 97.824 KiB antes de criar as quinze janelas para 97.792 KiB após as alternâncias. Não houve crescimento observado nessa rodada; isso não substitui um teste prolongado de vazamento.

## Como medir novamente

`Tools/MeasureResources.c` lê somente os contadores do processo pelo `proc_pid_rusage`, com uma espera finita de 1 a 30 segundos. Não acessa conteúdo de janelas, não solicita permissões e encerra após imprimir JSON. O binário temporário pode ser removido depois do uso.

```sh
xcrun clang -O2 -Wall -Wextra Tools/MeasureResources.c -o /tmp/TrioMeasureResources
/tmp/TrioMeasureResources PID_DO_TRIO 10
```

Os contadores de CPU do Darwin são ticks da base Mach, convertidos por `mach_timebase_info().numer / denom` antes de calcular a fração do intervalo. A implementação oficial do XNU atribui os campos a `powerinfo.total_user` e `total_system`, provenientes dos contadores Mach: [bsd_kern.c](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/osfmk/kern/bsd_kern.c#L1257-L1261), [task.c](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/osfmk/kern/task.c#L6807-L6812), [recount.h](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/osfmk/kern/recount.h#L133-L137).

## Trabalho em segundo plano

O motor reage a notificações AX, mudanças do Workspace, monitores e eventos de geometria. Não mantém uma varredura periódica das janelas. As novas tentativas de leitura têm limite. O timer da onda existe somente durante a transição de 220 ms e é invalidado ao terminar; a animação da janela também tem duração e quantidade de passos limitadas. O menu acompanha eventos do ponteiro enquanto está aberto. Não há rede nem inferência de IA no aplicativo.
