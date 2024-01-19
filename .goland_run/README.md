For now environment variables do not work in `Program Arguments` section in run/debug configuration.

That's the reason for creating these templates, so you can replace the provided environment variables with your custom/hardcoded values.

For each template:
1. duplicate the template xml file
2. the new file name should be the same without the `template` prefix (for git to ignore it). Example: `template-op-batcher-local.run.xml` to `op-batcher-local.run.xml`.
3. Edit the file and remove the `folderName="Templates"` attribute from the `configuration` xml tag for it to not be included in `Templates` folder within the configurations.
4. Edit the file and rename the `name` attribute from the `configuration` xml tag by removing `template` prefix. This is the name shown in the menu. Example: `name="template-op-node-local"` to `name="op-node-local"`.
5. Edit the file and replace the environment variables by the actual value (hardcode it). Example: `--l1=${L1_RPC_URL}` to `--l1=http://localhost:4444`.
6. Ready to debug!
