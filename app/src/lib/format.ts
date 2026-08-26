// Apenas formatacao de exibicao. Nenhum calculo financeiro vive aqui --
// esse e o papel exclusivo das views do banco (ver ESPECIFICACAO.md secao 3).

export function formatBRL(valor: number | null | undefined): string {
  return (valor ?? 0).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' });
}

export function todayISO(): string {
  const d = new Date();
  const tzOffsetMs = d.getTimezoneOffset() * 60_000;
  return new Date(d.getTime() - tzOffsetMs).toISOString().slice(0, 10);
}

export function rotuloCiclo(ciclo: string): string {
  return new Date(`${ciclo}T00:00:00`).toLocaleDateString('pt-BR', { month: 'long', year: 'numeric' });
}
