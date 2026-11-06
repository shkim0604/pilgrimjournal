import { html } from 'hono/html';
import { layout, type Html } from './layout.ts';

function errorBox(error?: string): Html | string {
  return error ? html`<p class="notice error" role="alert">${error}</p>` : '';
}

export function loginPage(opts: { error?: string; username?: string } = {}): Html {
  return layout({
    title: '로그인',
    nav: false,
    body: html`<form class="card narrow" method="post" action="/admin/login">
      ${errorBox(opts.error)}
      <label>아이디
        <input name="username" autocomplete="username" required value="${opts.username ?? ''}" autofocus>
      </label>
      <label>비밀번호
        <input name="password" type="password" autocomplete="current-password" required>
      </label>
      <button type="submit">로그인</button>
    </form>`,
  });
}

export function changePasswordPage(opts: { error?: string; forced: boolean }): Html {
  return layout({
    title: '비밀번호 변경',
    nav: !opts.forced,
    body: html`<form class="card narrow" method="post" action="/admin/change-password">
      ${opts.forced ? html`<p class="notice">처음 로그인했습니다. 계속하려면 비밀번호를 바꾸세요.</p>` : ''}
      ${errorBox(opts.error)}
      <label>현재 비밀번호
        <input name="current" type="password" autocomplete="current-password" required>
      </label>
      <label>새 비밀번호 (12자 이상)
        <input name="next" type="password" autocomplete="new-password" minlength="12" required>
      </label>
      <label>새 비밀번호 확인
        <input name="confirm" type="password" autocomplete="new-password" minlength="12" required>
      </label>
      <button type="submit">변경</button>
    </form>
    ${opts.forced ? html`<form class="logout-inline" method="post" action="/admin/logout"><button type="submit" class="link">로그아웃</button></form>` : ''}`,
  });
}

export function errorPage(status: number): Html {
  return layout({
    title: status === 404 ? '찾을 수 없음' : '오류',
    nav: false,
    body: html`<p class="card">${status === 404 ? '요청한 페이지가 없습니다.' : '요청을 처리하지 못했습니다. 잠시 후 다시 시도하세요.'}</p>
      <p><a href="/admin">관리 콘솔로 돌아가기</a></p>`,
  });
}
