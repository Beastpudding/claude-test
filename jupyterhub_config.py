# Copyright (c) Jupyter Development Team.
# Distributed under the terms of the Modified BSD License.

# Configuration file for JupyterHub
import os

c = get_config()  # noqa: F821

# ============================================================
# Docker Spawner 설정
# ============================================================
from dockerspawner import DockerSpawner


class DemoFormSpawner(DockerSpawner):
    """사용자가 이미지를 선택할 수 있는 폼을 제공하는 Spawner"""

    def _options_form_default(self):
        # 환경변수에서 기본 이미지를 가져옴
        default_image = os.environ.get(
            "DOCKER_NOTEBOOK_IMAGE", "codeserver-kbdev:local"
        )
        return """
        <label for="stack">원하는 스택을 고르세요.</label>
        <select name="stack" size="1">
            <option value="{default_image}">{default_image} (기본)</option>
        </select>
        """.format(default_image=default_image)

    def options_from_form(self, formdata):
        options = {}
        options['stack'] = formdata['stack']
        container_image = ''.join(formdata['stack'])
        self.log.info("SPAWN: %s IMAGE", container_image)
        # 올바른 속성명: self.image (self.container_image가 아님)
        self.image = container_image
        return options


c.JupyterHub.spawner_class = DemoFormSpawner

# ============================================================
# 기본 이미지 설정
# ============================================================
c.DockerSpawner.image = os.environ.get(
    "DOCKER_NOTEBOOK_IMAGE", "codeserver-kbdev:local"
)

# ============================================================
# Docker 네트워크 설정
# ============================================================
network_name = os.environ.get("DOCKER_NETWORK_NAME", "jupyterhub-network")
c.DockerSpawner.use_internal_ip = True
c.DockerSpawner.network_name = network_name

# ============================================================
# 노트북 디렉토리 설정
# ============================================================
notebook_dir = os.environ.get("DOCKER_NOTEBOOK_DIR", "/home/jovyan/work")
c.DockerSpawner.notebook_dir = notebook_dir

# ============================================================
# 볼륨 마운트 설정
# ============================================================
c.DockerSpawner.volumes = {
    "jupyterhub-user-{username}": notebook_dir,
    "vsix_files": "/home/jovyan/vsix_files",
}

# ============================================================
# 컨테이너 설정
# ============================================================
# 컨테이너 종료 시 자동 삭제
c.DockerSpawner.remove = True

# For debugging arguments passed to spawned containers
c.DockerSpawner.debug = True

# Spawn 타임아웃 (기본 30초 → 120초)
c.Spawner.start_timeout = 120
c.Spawner.http_timeout = 60

# 커스텀 런처 페이지를 기본 랜딩 페이지로 설정
c.Spawner.default_url = "/launcher"

# ============================================================
# Docker-in-Docker (DinD) 설정
# ============================================================
# privileged 모드: 각 사용자 컨테이너에서 독립된 Docker daemon 실행
c.DockerSpawner.extra_host_config = {
    "privileged": True,
}
# code-server가 사전설치된 extensions을 참조하도록 환경변수 설정
# jupyter-vscode-proxy가 CODE_EXTENSIONSDIR을 읽어서 --extensions-dir로 전달
c.DockerSpawner.environment = {
    "CODE_EXTENSIONSDIR": "/opt/code-server-extensions",
}

# ============================================================
# Hub 네트워크 설정 (핵심 수정사항!)
# ============================================================
# hub_ip: Hub 내부 API가 바인딩할 주소 (0.0.0.0 = 모든 인터페이스)
c.JupyterHub.hub_ip = "0.0.0.0"

# hub_port: Hub 내부 API 포트 (proxy 포트 8000과 달라야 함!)
# proxy는 8000번에서 동작하므로, hub API는 8081로 분리
c.JupyterHub.hub_port = 8081

# hub_connect_url: spawned container가 hub에 접근할 때 사용하는 URL
# Docker 네트워크에서는 컨테이너 이름(jupyterhub)을 사용해야 함
# "localhost"를 사용하면 spawned container에서 hub를 찾을 수 없음!
c.JupyterHub.hub_connect_url = "http://jupyterhub:8081"

# ============================================================
# 데이터 영속성
# ============================================================
c.JupyterHub.cookie_secret_file = "/data/jupyterhub_cookie_secret"
c.JupyterHub.db_url = "sqlite:////data/jupyterhub.sqlite"

# ============================================================
# 인증 설정
# ============================================================
c.JupyterHub.authenticator_class = "nativeauthenticator.NativeAuthenticator"

# 회원가입 허용
c.NativeAuthenticator.open_signup = True

# 로그인한 모든 사용자에게 Hub 접근 허용 (JupyterHub 5.x 필수)
c.Authenticator.allow_all = True

# 관리자 설정
admin = os.environ.get("JUPYTERHUB_ADMIN")
if admin:
    c.Authenticator.admin_users = [admin]
