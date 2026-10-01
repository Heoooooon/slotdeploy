# Render with: vhs demo/demo.tape   (from the repository root)
Output demo/demo.gif
Set Shell bash
Set FontSize 18
Set Width 1280
Set Height 720
Set Padding 24
Set TypingSpeed 25ms
Set Theme "Catppuccin Mocha"

Hide
Type "source demo/sandbox.sh && clear" Enter
Sleep 2s
Show

Type "site" Enter
Sleep 1s
Type "edit_page 'Opening hours: 9am-8pm (new!)'" Enter
Type "slotdeploy-push push 'Update opening hours'" Enter
Sleep 2s
Type "slotdeploy watch        # the server timer does this every minute" Enter
Sleep 2s
Type "site" Enter
Sleep 2s

Type "break_build             # oops: a broken change" Enter
Type "slotdeploy-push push 'Try a new layout'" Enter
Sleep 2s
Type "slotdeploy watch" Enter
Sleep 2.5s
Type "site                    # still the last good version" Enter
Sleep 3s

Type "slotdeploy-push rollback prev" Enter
Sleep 2s
Type "slotdeploy-push status" Enter
Sleep 4s
