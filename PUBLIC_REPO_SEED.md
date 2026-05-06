# Public Repository Seed

This archive was generated from a sanitized working copy.

Included:
- Project Zomboid mod files under `Contents/`
- Lua sources used by the Build 42 release path
- UI assets and Workshop preview image
- Workshop-safe file set: no blocked executable/archive extensions and
  `preview.png` is normalized below the Project Zomboid uploader size limit
- README and Workshop description files
- Public `.gitignore`
- Source reuse permission

Excluded:
- Git history
- Local deployment scripts
- Local test server scripts
- Private configuration and server settings
- Server backups and generated build caches
- Legacy Java source and compiled JAR artifacts from the private working tree

Suggested initial GitHub import:

```powershell
git init
git add .
git commit -m "Initial public release"
git branch -M main
git remote add origin <your-new-repository-url>
git push -u origin main
```