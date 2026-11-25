package com.guozhigq.pilipala;

import org.junit.Test;
import static org.junit.Assert.*;
import java.util.List;
import java.util.Map;

public class JapaneseTokenizerTest {
    private static final JapaneseTokenizer ENGINE = new JapaneseTokenizer();
    private String reading(String text) {
        StringBuilder output = new StringBuilder();
        for (Map<String, Object> token : ENGINE.analyze(text)) output.append(token.get("reading"));
        return output.toString();
    }

    @Test public void screenshotCompoundIsReadAsWords() {
        assertEquals("コッカアンゼンホショウ", reading("国家安全保障"));
        List<Map<String, Object>> tokens = ENGINE.analyze("国家安全保障");
        assertEquals(3, tokens.size());
        assertEquals("国家", tokens.get(0).get("surface"));
    }

    @Test public void compoundsAndInflectionsChooseDifferentReadings() {
        assertEquals("セイブツ", reading("生物"));
        assertEquals("イキモノ", reading("生き物"));
        assertEquals("ジョウズ", reading("上手"));
        assertEquals("ウマイ", reading("上手い"));
        assertEquals("ショクジ", reading("食事"));
        assertEquals("タベタ", reading("食べた"));
    }

    @Test public void positionsRetainWhitespacePunctuationAndSupplementaryUnicode() {
        String text = "😀 国家安全保障。\n生き物を見る";
        int last = 0;
        for (Map<String, Object> token : ENGINE.analyze(text)) {
            int start = (Integer) token.get("start");
            String surface = (String) token.get("surface");
            assertTrue(start >= last);
            assertEquals(surface, text.substring(start, start + surface.length()));
            if (!(Boolean)token.get("known")) assertEquals("", token.get("reading"));
            last = start + surface.length();
        }
    }

    @Test public void weekdaysAndCalendarTokensForDartIntegration() throws Exception {
        assertEquals("ゲツヨウビカヨウビスイヨウビモクヨウビキンヨウビドヨウビニチヨウビ",
                reading("月曜日火曜日水曜日木曜日金曜日土曜日日曜日"));
        String[] samples = {"国家安全保障", "生物と生き物", "四月と四か月", "7月と9月", "４月１日",
                "1日休む", "1日", "4日と14日と20日と24日", "1週間と8週間", "4時と7時と9時",
                "月曜日火曜日水曜日木曜日金曜日土曜日日曜日"};
        StringBuilder json = new StringBuilder("[");
        for (int i = 0; i < samples.length; i++) {
            if (i > 0) json.append(',');
            json.append("{\"text\":\"").append(samples[i]).append("\",\"tokens\":[");
            List<Map<String, Object>> tokens = ENGINE.analyze(samples[i]);
            for (int t = 0; t < tokens.size(); t++) {
                if (t > 0) json.append(',');
                Map<String, Object> token = tokens.get(t);
                json.append("{\"surface\":\"").append(token.get("surface"))
                    .append("\",\"reading\":\"").append(token.get("reading"))
                    .append("\",\"start\":").append(token.get("start"))
                    .append(",\"known\":").append(token.get("known")).append('}');
            }
            json.append("]}");
        }
        json.append(']');
        java.nio.file.Path target = java.nio.file.Paths.get("../../scratch/offline_check/japanese_native_tokens.json");
        java.nio.file.Files.createDirectories(target.getParent());
        java.nio.file.Files.write(target, json.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8));
    }
}
