# Contributor Identity Rewrite Plan (B-1)

## 目的

すべてのリポジトリの commit author を統一して、`bascule-aizu <aizu@bascule.co.jp>` から `Ido <ido@ojos.jp>` に置き換える。

現在の git identity:
```
Name: Ido
Email: ido@ojos.jp
```

## 対象リポジトリ（3 つ）

1. **ojos/ai-packages-dev** (dev repo)
   - Status: 一部 commits が古い identity で記録
   - Scope: すべての history rewrite

2. **ojos/ai-dotfiles** (dotfiles package)
   - Status: 古い identity残存の可能性
   - Scope: すべての history rewrite

3. **ojos/devcontainer-bootstrap** (devcontainer package)
   - Status: 古い identity残存の可能性
   - Scope: すべての history rewrite

---

## 実装方法: git filter-repo を使用

### Step 1: Identity Mapping ファイル作成

```bash
# For each repo:
printf 'Ido <ido@ojos.jp> <aizu@bascule.co.jp>\n' > /tmp/mailmap.txt
```

Mapping 形式:
```
新 identity <新メール> 旧 identity <旧メール>
```

### Step 2: git filter-repo 実行

```bash
git filter-repo --force --mailmap /tmp/mailmap.txt
```

効果:
- All commits with `bascule-aizu <aizu@bascule.co.jp>` → `Ido <ido@ojos.jp>`
- Branch/tag commit hashes will change
- Local repo diverges from origin (need force-push)

### Step 3: Force Push と Verification

```bash
git push --force origin --all
git push --force origin --tags

# Verify:
git log --all --format='%an <%ae>' | grep bascule-aizu
# Should return empty (no remaining old identity)
```

---

## Risks & Considerations

### High Risk
- **Force push**: すべての team member が re-clone 必要
- **CI/CD hooks**: すべての webhook が再実行される可能性
- **GitHub Actions**: commit hash が変わるため、artifact キャッシュが invalidate

### Mitigation
1. **事前通知**: Team に force-push をアナウンス
2. **Timing**: Office hours 外で実行
3. **Rollback plan**: Upstream backup 確認
4. **Verification**: Each repo で old identity 残存 check

### 手順の順序（重要）
- **dev repo 最後**: app-specific repo なので最後に
- **Package repos first**: 依存関係が上流なので先に

推奨順序:
1. ojos/ai-dotfiles
2. ojos/devcontainer-bootstrap
3. ojos/ai-packages-dev (last)

---

## Implementation Checklist

### Pre-Rewrite
- [ ] All team members notified
- [ ] Backup confirmed (GitHub keeps history)
- [ ] Verify current identity is `Ido <ido@ojos.jp>`
- [ ] Mailmap file prepared
- [ ] Each repo cloned to /tmp for testing

### Execution (Per Repo)
- [ ] Clone repo to /tmp/rewrite-[name]
- [ ] Create mailmap.txt
- [ ] Run `git filter-repo --force --mailmap ...`
- [ ] Verify old identity removed: `git log | grep bascule-aizu` → empty
- [ ] Force push: `git push --force origin --all && git push --force origin --tags`

### Post-Rewrite
- [ ] Verify on GitHub: commits show `Ido` author
- [ ] Local re-clone in dev container
- [ ] CI/CD pipelines still working
- [ ] Document completion in issue/PR

### Rollback (if needed)
- GitHub keeps full history (not affected by filter-repo)
- Can revert by restoring from branch protection rules or admin restore

---

## Expected Timeline

| Repo | Complexity | Est. Time |
|------|-----------|-----------|
| ai-dotfiles | Low (small repo) | 5 min |
| devcontainer-bootstrap | Low (small repo) | 5 min |
| ai-packages-dev | High (dev repo, large) | 20 min |
| **Total** | **Medium** | **~30 min** |

---

## Success Criteria

After completion:
- ✅ `git log --all --format='%an <%ae>'` shows only `Ido <ido@ojos.jp>`
- ✅ No `bascule-aizu <aizu@bascule.co.jp>` commits remain in any repo
- ✅ All repos successfully force-pushed to GitHub
- ✅ GitHub UI shows commits authored by `Ido`
- ✅ No CI/CD pipeline failures post-rewrite

---

## Notes

- Mailmap approach = non-destructive (original commits preserved, just shown differently)
- GitHub 側では automatic rewrite は not needed（filter-repo は local + push）

## Decision Point

**Go/No-Go**: ユーザーから実行許可を得てから進行

現在のステータス: **PLAN READY** - Awaiting user approval for execution

