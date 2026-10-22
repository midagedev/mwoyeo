-- Film 3's Accessibility steps (see ax.sh): attribute reads and AXPress / AXValue / AXPosition writes through System Events. No CGEvent.
-- usage: osascript ax.applescript dump|action|press|set|move <pid> [args]
on run argv
	set cmd to item 1 of argv
	set thePid to (item 2 of argv) as integer
	set res to ""
	set found to false
	tell application "System Events"
		tell (first process whose unix id is thePid)
			repeat with w in windows
				set wname to ""
				try
					set wname to name of w
				end try
				if cmd is "presslast" then
					if my nameMatches(wname, item 3 of argv) then
						set els to entire contents of w
						set lastBtn to missing value
						repeat with e in els
							try
								if (role of e as text) is (item 4 of argv) then set lastBtn to e
							end try
						end repeat
						if lastBtn is missing value then error "ax: no " & (item 4 of argv) & " in " & wname
						perform action "AXPress" of lastBtn
						return "pressed the last " & (item 4 of argv) & " of " & wname
					end if
				else if cmd is "bar" then
					if my nameMatches(wname, item 3 of argv) then
						set els to entire contents of w
						set best to missing value
						set bestH to 0
						set inSheet to false
						set hasSheet to false
						repeat with e in els
							try
								if (role of e as text) is "AXSheet" then set hasSheet to true
							end try
						end repeat
						repeat with e in els
							try
								if (role of e as text) is "AXSheet" then set inSheet to true
							end try
							try
								if (role of e as text) is "AXScrollArea" and (inSheet or not hasSheet) then
									set sz to size of e
									set h to (item 2 of sz) as integer
									if h > bestH then
										set bestH to h
										set best to e
									end if
								end if
							end try
						end repeat
						if best is missing value then error "ax: no scroll area in " & wname
						set bar to value of attribute "AXVerticalScrollBar" of best
						set value of bar to (item 4 of argv) as real
						return "bar " & wname & " = " & (item 4 of argv)
					end if
				else if cmd is "scroll" then
					if my nameMatches(wname, item 3 of argv) then
						set els to entire contents of w
						set best to missing value
						set bestH to 0
						set inSheet to false
						set hasSheet to false
						repeat with e in els
							try
								if (role of e as text) is "AXSheet" then set hasSheet to true
							end try
						end repeat
						repeat with e in els
							try
								if (role of e as text) is "AXSheet" then set inSheet to true
							end try
							try
								if (role of e as text) is "AXScrollArea" and (inSheet or not hasSheet) then
									set sz to size of e
									set h to (item 2 of sz) as integer
									if h > bestH then
										set bestH to h
										set best to e
									end if
								end if
							end try
						end repeat
						if best is missing value then error "ax: no scroll area in " & wname
						repeat (item 5 of argv as integer) times
							perform action (item 4 of argv) of best
							delay 0.25
						end repeat
						return "scrolled " & wname & " by " & (item 4 of argv) & " x " & (item 5 of argv)
					end if
				else if cmd is "move" then
					if my nameMatches(wname, item 3 of argv) then
						set position of w to {(item 4 of argv) as integer, (item 5 of argv) as integer}
						return "moved " & wname
					end if
				else
					if cmd is "dump" then set res to res & "WINDOW | " & wname & linefeed
					set els to entire contents of w
					repeat with e in els
						set r to ""
						try
							set r to (role of e as text)
						end try
						set t to ""
						set d to ""
						set v to ""
						try
							set t to (title of e as text)
						end try
						try
							set d to (description of e as text)
						end try
						try
							set v to (value of e as text)
						end try
						if t is "missing value" then set t to ""
						if d is "missing value" then set d to ""
						if v is "missing value" then set v to ""
						try
							set v to v as text
						on error
							set v to ""
						end try
						if cmd is "dump" then
							if (count of v) > 60 then set v to text 1 thru 60 of v
							set a to ""
							try
								repeat with x in (actions of e)
									set a to a & (name of x) & ";"
								end repeat
							end try
							set res to res & "  " & r & " | " & t & " | " & d & " | " & v & " | " & a & linefeed
						else if cmd is "action" then
							if (d & " " & t) contains (item 3 of argv) then
								repeat with x in (actions of e)
									if (name of x) contains (item 4 of argv) then
										perform x
										return "acted " & (name of x)
									end if
								end repeat
							end if
						else if cmd is "pressafter" then
							if (not found) and ((t & " " & d & " " & v) contains (item 3 of argv)) and r is not "AXStaticText" then
								set found to true
							else if found and r is (item 4 of argv) then
								perform action "AXPress" of e
								return "pressed the " & (item 4 of argv) & " after " & (item 3 of argv)
							end if
						else if cmd is "press" then
							if (t & " " & d & " " & v) contains (item 3 of argv) then
								try
									perform action "AXPress" of e
									return "pressed " & t & " " & d
								end try
							end if
						else if cmd is "type" then
							if (t & " " & d) contains (item 3 of argv) and (r is "AXTextArea" or r is "AXTextField") then
								set fullText to item 4 of argv
								set chunk to (item 5 of argv) as integer
								set pause to (item 6 of argv) as real
								set n to chunk
								repeat while n < (count of fullText)
									set value of e to (text 1 thru n of fullText)
									delay pause
									set n to n + chunk
								end repeat
								set value of e to fullText
								return "typed " & (count of fullText) & " characters into " & t & " " & d
							end if
						else if cmd is "set" then
							if (t & " " & d) contains (item 3 of argv) and (r is "AXTextArea" or r is "AXTextField") then
								set value of e to (item 4 of argv)
								return "set " & t & " " & d
							end if
						end if
					end repeat
				end if
			end repeat
		end tell
	end tell
	if cmd is "dump" then return res
	error "ax: nothing matched for " & cmd & " " & (item 3 of argv)
end run

-- a window text that starts with "=" must equal the window name; otherwise the name must contain it
on nameMatches(wname, key)
	if key starts with "=" then return wname is (text 2 thru -1 of key)
	return wname contains key
end nameMatches
