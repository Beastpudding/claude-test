# Copyright (c) Jupyter Development Team.
# Distributed under the terms of the Modified BSD License.

# Configuration file for JupyterHub
import os
# from jupyter_client.localinterfaces import public_ips

c = get_config()  # noqa: F821

# We rely on environment variables to configure JupyterHub so that we
# avoid having to rebuild the JupyterHub container every time we change a
# configuration parameter.

#from dockerspawner import SystemUserSpawner
from dockerspawner import DockerSpawner

class DemoFormSpawner(DockerSpawner):
    def _options_form_default(self):
        default_stack = "quay.io/beastpudding/codeserver-kbdev"
        return """
        <label for="stack">원하는 스택을 고르세요.</label>
        <select name="stack" size="1">
	<option value="intellijtest">test </option>
        <option value="beastpudding/codeserver-kbdev:latest">python-base </option>
        <option value="quay.io/beastpudding/python-pycharm">quay.io/beastpudding/python-pycharm </option>
	<option value="python-pycharm-tmp">python-pycharm-tmp </option>
	<option value="intellijtest2">intellijtest2 </option>
	</select>
        """.format(stack=default_stack)

    def options_from_form(self, formdata):
        options = {}
        options['stack'] = formdata['stack']
        container_image = ''.join(formdata['stack'])
        print("SPAWN: " + container_image + " IMAGE" )
        self.container_image = container_image
        return options

c.JupyterHub.spawner_class = DemoFormSpawner

class MultiDockerImageSpawner(DockerSpawner):
    images = {
        'Base-Codeserver': 'quay.io/beastpudding/codeserver-kbdev',
        'Spark-Intellij': 'sparkintellij',
    }
    def _options_form_default(self):
        outval = """
        <label for="image">Docker Image</label>
        <select name="image">
        """
        for name, image in self.images.items():
            outval += "<option value=\"%s\">%s (%s)</option>" % (name, name, image)

        outval += """
        </select>
        """
        return outval

    def options_from_form(self, formdata):
        options = {}
        options['image'] = formdata.get('image', ['SciPy'])[0]
        self.image = self.images[options['image']]
        return options

# Spawn single-user servers as Docker containers
# c.JupyterHub.spawner_class = "MultiDockerImageSpawner"

# Spawn containers from this image
c.DockerSpawner.image = os.environ["DOCKER_NOTEBOOK_IMAGE"]

# Connect containers to this Docker network
network_name = os.environ["DOCKER_NETWORK_NAME"]
#network_name = 'bridge'
c.DockerSpawner.use_internal_ip = True
c.DockerSpawner.network_name = network_name
#ip = public_ips()[0]
#c.JupyterHub.hub_ip = ip
#c.DockerSpawner.extra_host_config = { 'network_mode': network_name }
# Explicitly set notebook directory because we'll be mounting a volume to it.
# Most `jupyter/docker-stacks` *-notebook images run the Notebook server as
# user `kbdev`, and set the notebook directory to `/home/kbdev/work`.
# We follow the same convention.

#notebook_dir = os.environ.get("DOCKER_NOTEBOOK_DIR", "/home/kbdev/work")
notebook_dir = "/home/kbdev/work"
c.DockerSpawner.notebook_dir = notebook_dir

# Mount the real user's Docker volume on the host to the notebook user's
# notebook directory in the container
c.DockerSpawner.volumes = {
	"jupyterhub-user-{username}": notebook_dir,
	"vsix_files": "/home/kbdev/vsix_files",
#	"/var/run/docker.sock": "/var/run/docker.sock"
}

c.DockerSpawner.extra_host_config = {
   "privileged": True
}

# c.DockerSpawner.post_start_cmd= "sh -c 'mkdir -p /home/kbdev/.local/share/ && mv /home/kbdev/code-server /home/kbdev/.local/share'"
c.DockerSpawner.post_start_cmd= "sh -c 'mkdir -p /home/kbdev/.local/share/ && mv /home/kbdev/code-server /home/kbdev/.local/share'"

# Remove containers once they are stopped
c.DockerSpawner.remove = True

# For debugging arguments passed to spawned containers
c.DockerSpawner.debug = True

# User containers will access hub by container name on the Docker network
c.JupyterHub.hub_ip = "localhost"
#c.JupyterHub.hub_id = ip
c.JupyterHub.hub_port = 8080

# Persist hub data on volume mounted inside container
c.JupyterHub.cookie_secret_file = "/data/jupyterhub_cookie_secret"
c.JupyterHub.db_url = "sqlite:////data/jupyterhub.sqlite"

# Authenticate users with Native Authenticator
c.JupyterHub.authenticator_class = "nativeauthenticator.NativeAuthenticator"

# Allow anyone to sign-up without approval
c.NativeAuthenticator.open_signup = True

# Allowed admins
admin = os.environ.get("JUPYTERHUB_ADMIN")
if admin:
    c.Authenticator.admin_users = [admin]
