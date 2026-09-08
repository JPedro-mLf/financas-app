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

export function formatData(data: string): string {
  return new Date(`${data}T00:00:00`).toLocaleDateString('pt-BR');
}

// "28/08/2026 a 28/09/2026" -- o intervalo de datas que o ciclo cobre.
export function rotuloPeriodo(inicio: string, fim: string): string {
  return `${formatData(inicio)} a ${formatData(fim)}`;
}

const ROTULO_MEIO: Record<string, string> = {
  pix: 'Pix',
  credito: 'Crédito',
  debito: 'Débito',
  dinheiro: 'Dinheiro',
  boleto: 'Boleto',
  folha: 'Folha',
};

export function rotuloMeio(meio: string | null | undefined): string {
  if (!meio) return '';
  return ROTULO_MEIO[meio] ?? meio;
}

const ROTULO_ORIGEM: Record<string, string> = {
  avulso: 'Avulso',
  recorrente: 'Recorrente',
  parcelamento: 'Parcela',
};

export function rotuloOrigem(origem: string | null | undefined): string {
  if (!origem) return '';
  return ROTULO_ORIGEM[origem] ?? origem;
}
