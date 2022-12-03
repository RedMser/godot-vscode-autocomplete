extends Control


const maxLen = 128
const minSafeInt = -99999999999999
const maxSafeInt = 99999999999999
var _minWordMatchPos: Array = makeArray(maxLen * 2)
var _maxWordMatchPos: Array = makeArray(maxLen * 2)
var _diag: Array = []
var _table: Array = []
var _arrows: Array = []


func _init():
	_minWordMatchPos.resize(maxLen * 2)
	_minWordMatchPos.fill(0)
	_maxWordMatchPos.resize(maxLen * 2)
	_maxWordMatchPos.fill(0)
	_diag.resize(maxLen)
	_diag = _diag.map(func(_i): return makeArray(maxLen))
	_table.resize(maxLen)
	_table = _table.map(func(_i): return makeArray(maxLen))
	_arrows.resize(maxLen)
	_arrows = _arrows.map(func(_i): return makeArray(maxLen))


func makeArray(size: int) -> Array[int]:
	var a = []
	a.resize(size)
	a.fill(0)
	return a


func _on_line_edit_text_changed(new_text: String) -> void:
	var list = get_completion_items().map(func(item):
		var score = fuzzyScore(new_text, new_text.to_lower(), 0, item, item.to_lower(), 0, {})
		if score != null:
			score = score[0]
		return [item, score]
	).filter(func(stuff): return stuff[1] != null)
	list.sort_custom(func(a, b): return a[1] > b[1])
	$TextEdit.text = "\n".join(list.map(func(stuff): return "%s (%s)" % [stuff[0], stuff[1]]))

func get_completion_items():
	return get_method_list().map(func(m): return m["name"]).filter(func(m): return m != null)


func fuzzyScore(pattern: String, patternLow: String, patternStart: int, word: String, wordLow: String, wordStart: int, options: Dictionary):
	var patternLen = min(pattern.length(), maxLen)
	var wordLen = min(word.length(), maxLen)

	if patternStart >= patternLen || wordStart >= wordLen || (patternLen - patternStart) > (wordLen - wordStart):
		return null

	# Run a simple check if the characters of pattern occur
	# (in order) at all in word. If that isn't the case we
	# stop because no match will be possible
	if !isPatternInWord(patternLow, patternStart, patternLen, wordLow, wordStart, wordLen, true):
		return null

	# Find the max matching word position for each pattern position
	# NOTE: the min matching word position was filled in above, in the `isPatternInWord` call
	_fillInMaxWordMatchPos(patternLen, wordLen, patternStart, wordStart, patternLow, wordLow)

	var row: int = 1
	var column: int = 1

	var hasStrongFirstMatch = [false]

	# There will be a match, fill in tables
	for patternPos in range(patternStart, patternLen):
		# Reduce search space to possible matching word positions and to possible access from next row
		var minWordMatchPos = _minWordMatchPos[patternPos]
		var maxWordMatchPos = _maxWordMatchPos[patternPos]
		var nextMaxWordMatchPos = _maxWordMatchPos[patternPos + 1] if patternPos + 1 < patternLen else wordLen

		column = minWordMatchPos - wordStart + 1
		for wordPos in range(minWordMatchPos, nextMaxWordMatchPos):
			var score = minSafeInt
			var canComeDiag = false

			if wordPos <= maxWordMatchPos:
				score = _doScore(
					pattern, patternLow, patternPos, patternStart,
					word, wordLow, wordPos, wordLen, wordStart,
					_diag[row - 1][column - 1] == 0,
					hasStrongFirstMatch
				)

			var diagScore = 0
			if score != maxSafeInt:
				canComeDiag = true
				diagScore = score + _table[row - 1][column - 1]

			var canComeLeft = wordPos > minWordMatchPos
			var leftScore = _table[row][column - 1] + (-5 if _diag[row][column - 1] > 0 else 0) if canComeLeft else 0 # penalty for a gap start

			var canComeLeftLeft = wordPos > minWordMatchPos + 1 && _diag[row][column - 1] > 0
			var leftLeftScore = _table[row][column - 2] + (-5 if _diag[row][column - 2] > 0 else 0) if canComeLeftLeft else 0 # penalty for a gap start

			if canComeLeftLeft && (!canComeLeft || leftLeftScore >= leftScore) && (!canComeDiag || leftLeftScore >= diagScore):
				# always prefer choosing left left to jump over a diagonal because that means a match is earlier in the word
				_table[row][column] = leftLeftScore
				_arrows[row][column] = 3 # Arrow.LeftLeft
				_diag[row][column] = 0
			elif canComeLeft && (!canComeDiag || leftScore >= diagScore):
				# always prefer choosing left since that means a match is earlier in the word
				_table[row][column] = leftScore
				_arrows[row][column] = 2 # Arrow.Left
				_diag[row][column] = 0
			elif canComeDiag:
				_table[row][column] = diagScore
				_arrows[row][column] = 1 # Arrow.Diag
				_diag[row][column] = _diag[row - 1][column - 1] + 1
			else:
				push_error("not possible")
				return null
			column += 1
		row += 1

	if !hasStrongFirstMatch[0] && !options.get("firstMatchCanBeWeak", false):
		return null

	row -= 1
	column -= 1

	var result = [_table[row][column], wordStart]

	var backwardsDiagLength = 0
	var maxMatchColumn = 0

	while row >= 1:
		# Find the column where we go diagonally up
		var diagColumn = column
		while true:
			var arrow = _arrows[row][diagColumn]
			if arrow == 3: # Arrow.LeftLeft
				diagColumn = diagColumn - 2
			elif arrow == 2: # Arrow.Left
				diagColumn = diagColumn - 1
			else:
				# found the diagonal
				break
			if diagColumn >= 1:
				break

		# Overturn the "forwards" decision if keeping the "backwards" diagonal would give a better match
		if (
			backwardsDiagLength > 1 # only if we would have a contiguous match of 3 characters
			&& patternLow[patternStart + row - 1] == wordLow[wordStart + column - 1] # only if we can do a contiguous match diagonally
			&& !isUpperCaseAtPos(diagColumn + wordStart - 1, word, wordLow) # only if the forwards chose diagonal is not an uppercase
			&& backwardsDiagLength + 1 > _diag[row][diagColumn] # only if our contiguous match would be longer than the "forwards" contiguous match
		):
			diagColumn = column

		if diagColumn == column:
			# this is a contiguous match
			backwardsDiagLength += 1
		else:
			backwardsDiagLength = 1

		if !maxMatchColumn:
			# remember the last matched column
			maxMatchColumn = diagColumn

		row -= 1
		column = diagColumn - 1
		result.append(column)

	if wordLen == patternLen && options.get("boostFullMatch", true):
		# the word matches the pattern with all characters!
		# giving the score a total match boost (to come up ahead other words)
		result[0] += 2

	# Add 1 penalty for each skipped character in the word
	var skippedCharsCount = maxMatchColumn - patternLen
	result[0] -= skippedCharsCount

	return result


func isPatternInWord(patternLow: String, patternPos: int, patternLen: int, wordLow: String, wordPos: int, wordLen: int, fillMinWordPosArr: bool = false) -> bool:
	while patternPos < patternLen && wordPos < wordLen:
		if patternLow[patternPos] == wordLow[wordPos]:
			if fillMinWordPosArr:
				# Remember the min word position for each pattern position
				_minWordMatchPos[patternPos] = wordPos
			patternPos += 1
		wordPos += 1
	return patternPos == patternLen; # pattern must be exhausted


func _fillInMaxWordMatchPos(patternLen: int, wordLen: int, patternStart: int, wordStart: int, patternLow: String, wordLow: String):
	var patternPos = patternLen - 1
	var wordPos = wordLen - 1
	while patternPos >= patternStart && wordPos >= wordStart:
		if patternLow[patternPos] == wordLow[wordPos]:
			_maxWordMatchPos[patternPos] = wordPos
			patternPos -= 1
		wordPos -= 1


func isUpperCaseAtPos(pos: int, word: String, wordLow: String) -> bool:
	return word[pos] != wordLow[pos]


func isSeparatorAtPos(value: String, index: int) -> bool:
	if index < 0 || index >= value.length():
		return false
	var code = value.unicode_at(index)
	if (
		code == 95 || # CharCode.Underline
		code == 45 || # CharCode.Dash
		code == 46 || # CharCode.Period
		code == 32 || # CharCode.Space
		code == 47 || # CharCode.Slash
		code == 92 || # CharCode.Backslash
		code == 39 || # CharCode.SingleQuote
		code == 34 || # CharCode.DoubleQuote
		code == 58 || # CharCode.Colon
		code == 36 || # CharCode.DollarSign
		code == 60 || # CharCode.LessThan
		code == 62 || # CharCode.GreaterThan
		code == 40 || # CharCode.OpenParen
		code == 41 || # CharCode.CloseParen
		code == 91 || # CharCode.OpenSquareBracket
		code == 93 || # CharCode.CloseSquareBracket
		code == 123 || # CharCode.OpenCurlyBrace
		code == 125 # CharCode.CloseCurlyBrace
	):
			return true
	else:
#		if strings.isEmojiImprecise(code):
#			return true
		return false


func isWhitespaceAtPos(value: String, index: int) -> bool:
	if index < 0 || index >= value.length():
		return false
	var code = value.unicode_at(index)
	if (
		code == 32 || # CharCode.Space
		code == 9 # CharCode.Tab
	):
		return true
	else:
		return false


func _doScore(
	pattern: String, patternLow: String, patternPos: int, patternStart: int,
	word: String, wordLow: String, wordPos: int, wordLen: int, wordStart: int,
	newMatchStart: bool,
	outFirstMatchStrong: Array,
) -> int:
	if patternLow[patternPos] != wordLow[wordPos]:
		return minSafeInt

	var score = 1
	var isGapLocation = false
	if wordPos == (patternPos - patternStart):
		# common prefix: `foobar <-> foobaz`
		#                            ^^^^^
		score = 7 if pattern[patternPos] == word[wordPos] else 5

	elif isUpperCaseAtPos(wordPos, word, wordLow) && (wordPos == 0 || !isUpperCaseAtPos(wordPos - 1, word, wordLow)):
		# hitting upper-case: `foo <-> forOthers`
		#                              ^^ ^
		score = 7 if pattern[patternPos] == word[wordPos] else 5
		isGapLocation = true

	elif isSeparatorAtPos(wordLow, wordPos) && (wordPos == 0 || !isSeparatorAtPos(wordLow, wordPos - 1)):
		# hitting a separator: `. <-> foo.bar`
		#                                ^
		score = 5

	elif isSeparatorAtPos(wordLow, wordPos - 1) || isWhitespaceAtPos(wordLow, wordPos - 1):
		# post separator: `foo <-> bar_foo`
		#                              ^^^
		score = 5
		isGapLocation = true

	if score > 1 && patternPos == patternStart:
		outFirstMatchStrong[0] = true

	if !isGapLocation:
		isGapLocation = isUpperCaseAtPos(wordPos, word, wordLow) || isSeparatorAtPos(wordLow, wordPos - 1) || isWhitespaceAtPos(wordLow, wordPos - 1)

	if patternPos == patternStart: # first character in pattern
		if wordPos > wordStart:
			# the first pattern character would match a word character that is not at the word start
			# so introduce a penalty to account for the gap preceding this match
			score -= 3 if isGapLocation else 5
	else:
		if newMatchStart:
			# this would be the beginning of a new match (i.e. there would be a gap before this location)
			score += 2 if isGapLocation else 0
		else:
			# this is part of a contiguous match, so give it a slight bonus, but do so only if it would not be a preferred gap location
			score += 0 if isGapLocation else 1

	if wordPos + 1 == wordLen:
		# we always penalize gaps, but this gives unfair advantages to a match that would match the last character in the word
		# so pretend there is a gap after the last character in the word to normalize things
		score -= 3 if isGapLocation else 5

	return score
