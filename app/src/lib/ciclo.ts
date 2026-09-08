import { supabase } from './supabaseClient';

export type PeriodoCiclo = { inicio: string; fim: string };

// O intervalo de datas de um ciclo e regra de calendario (secao 4 da
// especificacao), entao quem calcula e o banco -- aqui so buscamos.
export async function periodoDoCiclo(ciclo: string): Promise<PeriodoCiclo | null> {
  const [inicioRes, fimRes] = await Promise.all([
    supabase.rpc('ciclo_inicio', { c: ciclo }),
    supabase.rpc('ciclo_fim', { c: ciclo }),
  ]);
  if (inicioRes.error || fimRes.error || !inicioRes.data || !fimRes.data) return null;
  return { inicio: inicioRes.data as string, fim: fimRes.data as string };
}
