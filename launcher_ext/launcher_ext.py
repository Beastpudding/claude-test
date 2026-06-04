"""
launcher_ext - JupyterHub 사용자 컨테이너용 커스텀 런처 페이지.

Jupyter Notebook, VS Code, Terminal 세 가지 환경으로 이동할 수 있는
랜딩 페이지를 제공하는 경량 Jupyter Server Extension.
외부 리소스 없이 인라인 HTML/CSS/JS만 사용 (air-gapped 환경 호환).
"""
from jupyter_server.base.handlers import JupyterHandler
from jupyter_server.utils import url_path_join
import tornado.web


LAUNCHER_HTML = r"""<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>KB 표준개발환경</title>
    <style>
        *, *::before, *::after {
            box-sizing: border-box;
            margin: 0;
            padding: 0;
        }

        body {
	    font-family: "Pretendard", -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto,
                         "Helvetica Neue", Arial, "Noto Sans KR", sans-serif;
            background: linear-gradient(135deg, #1a1a2e 0%, #16213e 40%, #0f3460 100%);
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            color: #e2e8f0;
        }

        /* ---- Top navigation bar ---- */
        .topbar {
            position: fixed;
            top: 0;
            left: 0;
            right: 0;
            height: 56px;
            display: flex;
            align-items: center;
            justify-content: space-between;
            padding: 0 1.5rem;
            z-index: 100;
            background: rgba(15, 23, 42, 0.65);
            backdrop-filter: blur(12px);
            border-bottom: 1px solid rgba(51, 65, 85, 0.5);
        }

        .topbar-left, .topbar-right {
            display: flex;
            align-items: center;
            gap: 0.5rem;
        }

        .topbar-btn {
            display: inline-flex;
            align-items: center;
            gap: 0.5rem;
            padding: 0.45rem 1rem;
            border-radius: 10px;
            font-size: 0.85rem;
            font-weight: 500;
            text-decoration: none;
            color: #cbd5e1;
            background: rgba(51, 65, 85, 0.45);
            border: 1px solid rgba(71, 85, 105, 0.5);
            cursor: pointer;
            transition: all 0.2s ease;
            white-space: nowrap;
        }

        .topbar-btn:hover {
            color: #f1f5f9;
            background: rgba(71, 85, 105, 0.6);
            border-color: rgba(100, 116, 139, 0.7);
        }

        .topbar-btn svg {
            width: 16px;
            height: 16px;
            flex-shrink: 0;
        }

        .topbar-btn.btn-logout {
            color: #fca5a5;
            border-color: rgba(239, 68, 68, 0.3);
            background: rgba(239, 68, 68, 0.08);
        }

        .topbar-btn.btn-logout:hover {
            color: #fef2f2;
            background: rgba(239, 68, 68, 0.2);
            border-color: rgba(239, 68, 68, 0.5);
        }

        .container {
            text-align: center;
            padding: 2rem;
            padding-top: 4rem;
            max-width: 960px;
            width: 100%;
        }

        .title {
            font-size: 2.5rem;
            font-weight: 700;
            margin-bottom: 0.5rem;
            color: #f8fafc;
            letter-spacing: -0.025em;
        }

	.title .kb-accent {
            color: #FFBC00;
        }

        .subtitle {
            font-size: 1.125rem;
            color: #94a3b8;
            margin-bottom: 3rem;
        }

        .cards {
            display: grid;
            grid-template-columns: repeat(3, 1fr);
            gap: 1.5rem;
        }

        .card {
            background: rgba(30, 41, 59, 0.8);
            backdrop-filter: blur(12px);
            border: 1px solid #334155;
            border-radius: 20px;
            padding: 2.5rem 1.5rem 2rem;
            text-decoration: none;
            color: #e2e8f0;
            transition: transform 0.25s cubic-bezier(0.4, 0, 0.2, 1),
                        box-shadow 0.25s cubic-bezier(0.4, 0, 0.2, 1),
                        border-color 0.25s cubic-bezier(0.4, 0, 0.2, 1);
            cursor: pointer;
            display: flex;
            flex-direction: column;
            align-items: center;
            position: relative;
            overflow: hidden;
        }

        .card::before {
            content: "";
            position: absolute;
            top: 0;
            left: 0;
            right: 0;
            height: 3px;
            opacity: 0;
            transition: opacity 0.25s ease;
        }

        .card:hover {
            transform: translateY(-8px);
        }

        .card:hover::before {
            opacity: 1;
        }

        .card:active {
            transform: translateY(-4px);
        }

        /* Jupyter */
        .card-jupyter::before { background: linear-gradient(90deg, #F37626, #f59e0b); }
        .card-jupyter:hover {
            border-color: #F37626;
            box-shadow: 0 24px 48px rgba(243, 118, 38, 0.15),
                        0 0 0 1px rgba(243, 118, 38, 0.1);
        }
        .card-jupyter .card-icon-wrap { background: rgba(243, 118, 38, 0.1); }

        /* VS Code */
        .card-vscode::before { background: linear-gradient(90deg, #007ACC, #3b82f6); }
        .card-vscode:hover {
            border-color: #007ACC;
            box-shadow: 0 24px 48px rgba(0, 122, 204, 0.15),
                        0 0 0 1px rgba(0, 122, 204, 0.1);
        }
        .card-vscode .card-icon-wrap { background: rgba(0, 122, 204, 0.1); }

        /* Terminal */
        .card-gitlab::before { background: linear-gradient(90deg, #FC6D26, #FCA326); }
        .card-gitlab:hover {
          transform: translateY(-2px);
          box-shadow: 0 12px 24px rgba(252, 109, 38, 0.15);
        }
        .card-gitlab .card-icon-wrap { background: rgba(252, 109, 38, 0.1); }

        .card-terminal::before { background: linear-gradient(90deg, #16a34a, #4ade80); }
        .card-terminal:hover {
            border-color: #16a34a;
            box-shadow: 0 24px 48px rgba(22, 163, 74, 0.15),
                        0 0 0 1px rgba(22, 163, 74, 0.1);
        }
        .card-terminal .card-icon-wrap { background: rgba(22, 163, 74, 0.1); }

        .card-icon-wrap {
            width: 80px;
            height: 80px;
            border-radius: 20px;
            display: flex;
            align-items: center;
            justify-content: center;
            margin-bottom: 1.5rem;
            transition: transform 0.25s ease;
        }

        .card:hover .card-icon-wrap {
            transform: scale(1.08);
        }

        .card-icon-wrap svg {
            width: 44px;
            height: 44px;
        }

        .card-title {
            font-size: 1.25rem;
            font-weight: 600;
            margin-bottom: 0.5rem;
            letter-spacing: -0.01em;
        }

        .card-desc {
            font-size: 0.875rem;
            color: #94a3b8;
            line-height: 1.6;
        }

        @media (max-width: 768px) {
            .cards {
                grid-template-columns: 1fr;
                max-width: 380px;
                margin: 0 auto;
            }
            .title { font-size: 1.75rem; }
            .subtitle { margin-bottom: 2rem; }
            .topbar { padding: 0 1rem; }
            .topbar-btn span.btn-label { display: none; }
            .topbar-btn { padding: 0.45rem 0.65rem; }
        }
    </style>
</head>
<body>
    <!-- 상단 네비게이션 바 -->
    <nav class="topbar">
        <div class="topbar-left">
            <a href="/hub/home" class="topbar-btn">
                <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
                    <rect x="2" y="2" width="12" height="12" rx="2"/>
                    <path d="M5.5 6h5M5.5 8.5h5M5.5 11h3"/>
                </svg>
                <span class="btn-label">설정</span>
            </a>
        </div>
        <div class="topbar-right">
            <a href="/hub/logout" class="topbar-btn btn-logout">
                <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
                    <path d="M6 14H3.33A1.33 1.33 0 0 1 2 12.67V3.33A1.33 1.33 0 0 1 3.33 2H6"/>
                    <polyline points="10.67 11.33 14 8 10.67 4.67"/>
                    <line x1="14" y1="8" x2="6" y2="8"/>
                </svg>
                <span class="btn-label">로그아웃</span>
            </a>
        </div>
    </nav>

    <div class="container">
        <h1 class="title"><span class="kb-accent">KB</span> 표준개발환경</h1>
        <p class="subtitle">데이터시스템부(P)</p>
	<div class="cards">
            <a href="BASE_URL_PLACEHOLDERlab" class="card card-jupyter">
                <div class="card-icon-wrap">
                    <svg viewBox="0 0 44 44" fill="none" xmlns="http://www.w3.org/2000/svg">
                        <path d="M22 2C22 2 8 10 8 22s14 20 14 20" stroke="#F37626" stroke-width="2.5" stroke-linecap="round" fill="none"/>
                        <path d="M22 2C22 2 36 10 36 22s-14 20-14 20" stroke="#F37626" stroke-width="2.5" stroke-linecap="round" fill="none"/>
                        <circle cx="22" cy="6" r="3" fill="#F37626"/>
                        <circle cx="22" cy="38" r="3" fill="#F37626" opacity="0.5"/>
                        <line x1="6" y1="22" x2="38" y2="22" stroke="#F37626" stroke-width="2" stroke-linecap="round" opacity="0.4"/>
                    </svg>
                </div>
                <div class="card-title">Jupyter Notebook</div>
                <div class="card-desc">데이터 분석 및 시각화를 위한<br>대화형 노트북 환경</div>
	    </a>
            <a href="BASE_URL_PLACEHOLDERvscode/" class="card card-vscode">
                <div class="card-icon-wrap">
                    <svg viewBox="0 0 44 44" fill="none" xmlns="http://www.w3.org/2000/svg">
                        <path d="M30 5L14 20l16 15" stroke="#007ACC" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" fill="none"/>
                        <line x1="30" y1="5" x2="30" y2="40" stroke="#007ACC" stroke-width="2.5" stroke-linecap="round"/>
                        <path d="M14 20L4 14" stroke="#007ACC" stroke-width="2.5" stroke-linecap="round" fill="none"/>
                        <path d="M14 20L4 26" stroke="#007ACC" stroke-width="2.5" stroke-linecap="round" fill="none"/>
                    </svg>
                </div>
                <div class="card-title">VS Code</div>
		<div class="card-desc">코드 작성 및 디버깅을 위한<br>웹 기반 통합 개발 환경</div>                
            </a>
            <a href="javascript:void(0)" onclick="openTerminal()" class="card card-terminal">
                <div class="card-icon-wrap">
                    <svg viewBox="0 0 44 44" fill="none" xmlns="http://www.w3.org/2000/svg">
                        <rect x="4" y="6" width="36" height="32" rx="6" stroke="#16a34a" stroke-width="2.5" fill="none"/>
                        <path d="M12 18l6 5-6 5" stroke="#16a34a" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"/>
                        <line x1="22" y1="28" x2="32" y2="28" stroke="#16a34a" stroke-width="2.5" stroke-linecap="round"/>
                    </svg>
                </div>
                <div class="card-title">터미널</div>
                <div class="card-desc">서버 명령어 실행을 위한<br>커맨드라인 셸 환경</div>
	    </a>
            <a href="GITLAB_URL_PLACEHOLDER" target="_blank" rel="noopener" class="card card-gitlab">
                <div class="card-icon-wrap">
                    <svg viewBox="0 0 44 44" fill="none" xmlns="http://www.w3.org/2000/svg">
                        <path d="M22 38 L4 24 L8 12 L14 28 L22 12 L30 28 L36 12 L40 24 Z" fill="#FC6D26" stroke="#E24329" stroke-width="1.2" stroke-linejoin="round"/>
                    </svg>
                </div>
                <div class="card-title">GitLab</div>
                <div class="card-desc">소스 코드 저장소 및<br>버전 관리 시스템</div>
            </a>
        </div>
    </div>
    <script>
        function getCookie(name) {
            var match = document.cookie.match(new RegExp('(^| )' + name + '=([^;]+)'));
            return match ? match[2] : '';
        }

        async function openTerminal() {
            var baseUrl = "BASE_URL_PLACEHOLDER";
            try {
                var resp = await fetch(baseUrl + "api/terminals", {
                    method: "POST",
                    headers: {
                        "Content-Type": "application/json",
                        "X-XSRFToken": getCookie("_xsrf")
                    }
                });
                if (resp.ok) {
                    var data = await resp.json();
                    window.location.href = baseUrl + "terminals/" + data.name;
                } else {
                    window.location.href = baseUrl + "terminals/1";
                }
            } catch (e) {
                window.location.href = baseUrl + "terminals/1";
            }
        }
    </script>
</body>
</html>"""


class LauncherHandler(JupyterHandler):
    """커스텀 런처 랜딩 페이지 핸들러."""

    @tornado.web.authenticated
    def get(self):
        import os
        base_url = self.application.settings.get("base_url", "/")
        if not base_url.endswith("/"):
            base_url += "/"
        gitlab_url = os.environ.get("GITLAB_URL", "")
        html = (LAUNCHER_HTML
                .replace("BASE_URL_PLACEHOLDER", base_url)
                .replace("GITLAB_URL_PLACEHOLDER", gitlab_url))
        self.set_header("Content-Type", "text/html; charset=UTF-8")
        self.finish(html)


def _load_jupyter_server_extension(serverapp):
    """Jupyter Server에 런처 핸들러 등록."""
    web_app = serverapp.web_app
    base_url = web_app.settings.get("base_url", "/")
    route = url_path_join(base_url, "/launcher")
    web_app.add_handlers(".*$", [(route, LauncherHandler)])
    serverapp.log.info("Custom launcher extension loaded, serving at %s", route)


def _jupyter_server_extension_points():
    """Jupyter Server Extension 진입점 선언."""
    return [{"module": "launcher_ext"}]
