import { supabase } from '../lib/supabaseClient';
import { formatBRL } from '../lib/format';

type Config = { dia_fechamento: number; dia_vencimento: number; horizonte_meses: number };
type Categoria = { id: string; nome: string; tipo: 'receita' | 'despesa'; ativa: boolean };
type Desconto = { id: string; descricao: string; percentual: number | null; valor_fixo: number | null };

export async function renderConfiguracao(page: HTMLElement): Promise<void> {
  page.innerHTML = `<p>Carregando configuracao...</p>`;

  const [userRes, configRes, categoriasRes, descontosRes, factorsRes] = await Promise.all([
    supabase.auth.getUser(),
    supabase.from('config').select('*').maybeSingle(),
    supabase.from('categorias').select('id, nome, tipo, ativa').order('nome'),
    supabase.from('descontos_folha').select('id, descricao, percentual, valor_fixo').order('descricao'),
    supabase.auth.mfa.listFactors(),
  ]);

  const userId = userRes.data.user?.id;
  const config = configRes.data as Config | null;
  const categorias = (categoriasRes.data ?? []) as Categoria[];
  const descontos = (descontosRes.data ?? []) as Desconto[];
  const mfaAtivo = (factorsRes.data?.totp ?? []).some((f) => f.status === 'verified');

  page.innerHTML = `
    <h1>Configuracao</h1>

    <section class="cartao">
      <h2>Ciclo</h2>
      <form id="form-config" class="form">
        <label>Dia de fechamento da fatura
          <input type="number" name="dia_fechamento" min="1" max="31" value="${config?.dia_fechamento ?? 27}" required>
        </label>
        <label>Dia de vencimento da fatura
          <input type="number" name="dia_vencimento" min="1" max="31" value="${config?.dia_vencimento ?? 3}" required>
        </label>
        <label>Horizonte de previsao (meses)
          <input type="number" name="horizonte_meses" min="1" max="24" value="${config?.horizonte_meses ?? 3}" required>
        </label>
        <button type="submit">Salvar</button>
        <p class="msg" id="msg-config" hidden></p>
      </form>
    </section>

    <section class="cartao">
      <h2>Categorias</h2>
      <ul>
        ${categorias.map((c) => `<li>${c.nome} (${c.tipo})${c.ativa ? '' : ' — inativa'}</li>`).join('') || '<li>Nenhuma categoria ainda.</li>'}
      </ul>
      <form id="form-categoria" class="form">
        <label>Nome<input type="text" name="nome" required></label>
        <label>Tipo
          <select name="tipo" required>
            <option value="despesa">Despesa</option>
            <option value="receita">Receita</option>
          </select>
        </label>
        <button type="submit">Adicionar</button>
        <p class="msg" id="msg-categoria" hidden></p>
      </form>
    </section>

    <section class="cartao">
      <h2>Descontos em folha</h2>
      <ul>
        ${descontos.map((d) => `<li>${d.descricao}: ${d.percentual != null ? `${d.percentual}%` : formatBRL(d.valor_fixo)}</li>`).join('') || '<li>Nenhum desconto ainda.</li>'}
      </ul>
      <form id="form-desconto" class="form">
        <label>Descricao<input type="text" name="descricao" required></label>
        <label>Percentual (%)<input type="number" name="percentual" step="0.0001"></label>
        <label>ou valor fixo (R$)<input type="number" name="valor_fixo" step="0.01"></label>
        <button type="submit">Adicionar</button>
        <p class="msg" id="msg-desconto" hidden></p>
      </form>
    </section>

    <section class="cartao">
      <h2>Autenticacao em duas etapas</h2>
      <p>${mfaAtivo ? 'MFA ativo nesta conta.' : 'MFA ainda nao configurado.'}</p>
      ${mfaAtivo ? '' : '<button id="btn-mfa-enroll" type="button">Ativar MFA</button>'}
      <div id="mfa-enroll-area"></div>
    </section>
  `;

  wireConfigForm(page, userId);
  wireCategoriaForm(page);
  wireDescontoForm(page);
  wireMfaEnroll(page);
}

function wireConfigForm(page: HTMLElement, userId: string | undefined): void {
  const form = page.querySelector<HTMLFormElement>('#form-config')!;
  const msg = page.querySelector<HTMLParagraphElement>('#msg-config')!;

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const dados = new FormData(form);

    const { error } = await supabase.from('config').upsert({
      user_id: userId,
      dia_fechamento: Number(dados.get('dia_fechamento')),
      dia_vencimento: Number(dados.get('dia_vencimento')),
      horizonte_meses: Number(dados.get('horizonte_meses')),
    });

    msg.hidden = false;
    msg.textContent = error ? `Erro: ${error.message}` : 'Salvo.';
    msg.className = error ? 'msg erro' : 'msg sucesso';
  });
}

function wireCategoriaForm(page: HTMLElement): void {
  const form = page.querySelector<HTMLFormElement>('#form-categoria')!;
  const msg = page.querySelector<HTMLParagraphElement>('#msg-categoria')!;

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const dados = new FormData(form);

    const { error } = await supabase.from('categorias').insert({
      nome: String(dados.get('nome')),
      tipo: String(dados.get('tipo')),
    });

    msg.hidden = false;
    if (error) {
      msg.textContent = `Erro: ${error.message}`;
      msg.className = 'msg erro';
    } else {
      msg.textContent = 'Categoria adicionada. Recarregue a tela para ve-la na lista.';
      msg.className = 'msg sucesso';
      form.reset();
    }
  });
}

function wireDescontoForm(page: HTMLElement): void {
  const form = page.querySelector<HTMLFormElement>('#form-desconto')!;
  const msg = page.querySelector<HTMLParagraphElement>('#msg-desconto')!;

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const dados = new FormData(form);
    const percentual = dados.get('percentual') ? Number(dados.get('percentual')) : null;
    const valorFixo = dados.get('valor_fixo') ? Number(dados.get('valor_fixo')) : null;

    const { error } = await supabase.from('descontos_folha').insert({
      descricao: String(dados.get('descricao')),
      percentual,
      valor_fixo: valorFixo,
    });

    msg.hidden = false;
    if (error) {
      msg.textContent = `Erro: ${error.message}`;
      msg.className = 'msg erro';
    } else {
      msg.textContent = 'Desconto adicionado. Recarregue a tela para ve-lo na lista.';
      msg.className = 'msg sucesso';
      form.reset();
    }
  });
}

function wireMfaEnroll(page: HTMLElement): void {
  const btn = page.querySelector<HTMLButtonElement>('#btn-mfa-enroll');
  if (!btn) return;
  const area = page.querySelector<HTMLDivElement>('#mfa-enroll-area')!;

  btn.addEventListener('click', async () => {
    area.innerHTML = `<p>Gerando QR code...</p>`;

    // Uma tentativa anterior que gerou QR mas nao foi confirmada deixa um
    // fator "unverified" pendente. Como o enroll nao recebe friendlyName, uma
    // nova tentativa colide com esse fator preso ("A factor with the friendly
    // name already exists"). Limpa qualquer fator TOTP nao verificado antes
    // de gerar um QR novo, para que tentar de novo sempre funcione.
    const { data: existentes } = await supabase.auth.mfa.listFactors();
    for (const fator of existentes?.all ?? []) {
      if (fator.factor_type === 'totp' && fator.status === 'unverified') {
        await supabase.auth.mfa.unenroll({ factorId: fator.id });
      }
    }

    const { data, error } = await supabase.auth.mfa.enroll({ factorType: 'totp' });

    if (error || !data) {
      area.innerHTML = `<p class="msg erro">Erro ao iniciar MFA: ${error?.message ?? ''}</p>`;
      return;
    }

    area.innerHTML = `
      <div class="qr-mfa"><img id="mfa-qr-img" alt="QR code do autenticador"></div>
      <p class="msg">Nao conseguiu escanear? Digite esta chave manualmente no app
        autenticador: <code id="mfa-secret"></code></p>
      <form id="form-mfa-verify" class="form">
        <label>Codigo do autenticador<input type="text" name="codigo" inputmode="numeric" required></label>
        <button type="submit">Confirmar</button>
        <p class="msg" id="msg-mfa" hidden></p>
      </form>
    `;

    // Atribuido via propriedade do DOM, nunca interpolado dentro do HTML: o
    // data URI do SVG traz aspas literais, que quebrariam o atributo
    // src="..." se fosse inserido direto no template (bug ja visto em teste).
    (area.querySelector('#mfa-qr-img') as HTMLImageElement).src = data.totp.qr_code;
    area.querySelector('#mfa-secret')!.textContent = data.totp.secret;

    const verifyForm = area.querySelector<HTMLFormElement>('#form-mfa-verify')!;
    const msgMfa = area.querySelector<HTMLParagraphElement>('#msg-mfa')!;

    verifyForm.addEventListener('submit', async (e) => {
      e.preventDefault();
      const codigo = String(new FormData(verifyForm).get('codigo'));

      const { error: verifyError } = await supabase.auth.mfa.challengeAndVerify({
        factorId: data.id,
        code: codigo,
      });

      msgMfa.hidden = false;
      msgMfa.textContent = verifyError ? `Erro: ${verifyError.message}` : 'MFA ativado. Recarregue a tela.';
      msgMfa.className = verifyError ? 'msg erro' : 'msg sucesso';
    });
  });
}
