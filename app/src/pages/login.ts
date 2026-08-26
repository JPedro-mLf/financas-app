import { supabase } from '../lib/supabaseClient';
import { navigate } from '../router';

export async function renderLogin(root: HTMLElement): Promise<void> {
  root.innerHTML = `
    <div class="auth-screen">
      <h1>Financas</h1>
      <form id="login-form" class="form">
        <label>E-mail<input type="email" name="email" required autocomplete="username"></label>
        <label>Senha<input type="password" name="password" required autocomplete="current-password"></label>
        <button type="submit">Entrar</button>
        <p class="msg erro" id="login-erro" hidden></p>
      </form>
      <form id="mfa-form" class="form" hidden>
        <label>Codigo do autenticador<input type="text" name="codigo" inputmode="numeric" pattern="[0-9]*" required autocomplete="one-time-code"></label>
        <button type="submit">Confirmar</button>
        <p class="msg erro" id="mfa-erro" hidden></p>
      </form>
    </div>
  `;

  const loginForm = root.querySelector<HTMLFormElement>('#login-form')!;
  const mfaForm = root.querySelector<HTMLFormElement>('#mfa-form')!;
  const loginErro = root.querySelector<HTMLParagraphElement>('#login-erro')!;
  const mfaErro = root.querySelector<HTMLParagraphElement>('#mfa-erro')!;

  loginForm.addEventListener('submit', async (e) => {
    e.preventDefault();
    loginErro.hidden = true;
    const dados = new FormData(loginForm);

    const { error } = await supabase.auth.signInWithPassword({
      email: String(dados.get('email')),
      password: String(dados.get('password')),
    });

    if (error) {
      loginErro.textContent = error.message;
      loginErro.hidden = false;
      return;
    }

    await afterPasswordStep();
  });

  async function afterPasswordStep(): Promise<void> {
    const { data: aal } = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
    if (aal && aal.nextLevel === 'aal2' && aal.nextLevel !== aal.currentLevel) {
      loginForm.hidden = true;
      mfaForm.hidden = false;
      return;
    }
    navigate('/');
  }

  mfaForm.addEventListener('submit', async (e) => {
    e.preventDefault();
    mfaErro.hidden = true;
    const dados = new FormData(mfaForm);
    const codigo = String(dados.get('codigo'));

    const { data: factors, error: factorsError } = await supabase.auth.mfa.listFactors();
    const factorId = factors?.totp?.[0]?.id;
    if (factorsError || !factorId) {
      mfaErro.textContent = 'Nenhum fator de MFA encontrado para esta conta.';
      mfaErro.hidden = false;
      return;
    }

    const { error } = await supabase.auth.mfa.challengeAndVerify({ factorId, code: codigo });
    if (error) {
      mfaErro.textContent = error.message;
      mfaErro.hidden = false;
      return;
    }

    navigate('/');
  });
}
