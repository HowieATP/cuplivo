package com.cup11.cuplivo

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidWebChatViewTest {
  @Test
  fun allowsOnlyBundledWebChatAssetsAndMermaid() {
    assertTrue(
      isAllowedWebChatAssetPath("flutter_assets/assets/web_chat/index.html"),
    )
    assertTrue(
      isAllowedWebChatAssetPath("flutter_assets/assets/web_chat/vendor/fonts/font.woff2"),
    )
    assertTrue(
      isAllowedWebChatAssetPath("flutter_assets/assets/mermaid.min.js"),
    )
    assertFalse(isAllowedWebChatAssetPath("flutter_assets/assets/app_icon.png"))
    assertFalse(
      isAllowedWebChatAssetPath("flutter_assets/assets/web_chat/../../app_icon.png"),
    )
    assertFalse(isAllowedWebChatAssetPath("/flutter_assets/assets/web_chat/index.html"))
  }

  @Test
  fun servesModulesWithJavaScriptMimeType() {
    assertEquals("text/html", webChatAssetMimeType("index.html"))
    assertEquals("text/css", webChatAssetMimeType("styles.css"))
    assertEquals("text/javascript", webChatAssetMimeType("app.mjs"))
    assertEquals("text/javascript", webChatAssetMimeType("mermaid.min.js"))
    assertEquals("font/woff2", webChatAssetMimeType("font.woff2"))
    assertEquals("application/octet-stream", webChatAssetMimeType("unknown.bin"))
  }
}
