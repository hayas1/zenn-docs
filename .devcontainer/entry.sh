#! /bin/bash -e

# change home directory owner from root
echo "change home directory ${HOME} owner to ${USER}..."
sudo chown -R "${USER}:${USER}" "${HOME}"
echo "done"

# for develop with python
# if [ -e "./requirements.txt" ]; then
#     pip install -r "./requirements.txt"
# fi

# for develop with go
# if type go >/dev/null 2>&1; then
#     go install -v golang.org/x/tools/gopls@latest
# fi

# project settings
# EXAMPLE:
# npm install -g @devcontainers/cli
# gh extension install https://github.com/nektos/gh-act
