package com.guozhigq.pilipala;

import com.atilika.kuromoji.ipadic.Token;
import com.atilika.kuromoji.ipadic.Tokenizer;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/** Whole-sentence morphological analysis; never guesses readings per kanji. */
public final class JapaneseTokenizer {
    private final Tokenizer tokenizer = new Tokenizer();

    public List<Map<String, Object>> analyze(String sentence) {
        if (sentence.length() > 4096) throw new IllegalArgumentException("Sentence too long");
        List<Map<String, Object>> result = new ArrayList<>();
        for (Token token : tokenizer.tokenize(sentence)) {
            Map<String, Object> item = new HashMap<>();
            item.put("surface", token.getSurface());
            item.put("start", token.getPosition()); // UTF-16, same as Dart String offsets
            String reading = token.isKnown() ? token.getReading() : "";
            item.put("reading", "*".equals(reading) ? "" : reading);
            item.put("known", token.isKnown());
            result.add(item);
        }
        return result;
    }
}
