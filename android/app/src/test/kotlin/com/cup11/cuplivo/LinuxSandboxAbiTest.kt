package com.cup11.cuplivo

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LinuxSandboxAbiTest {
  @Test
  fun selectsArmV7ForA32BitProcessOnArm64Hardware() {
    assertEquals(
      "armeabi-v7a",
      selectSandboxAbi(arrayOf("arm64-v8a", "armeabi-v7a"), false),
    )
  }

  @Test
  fun selectsPublished64BitAbis() {
    assertEquals(
      "arm64-v8a",
      selectSandboxAbi(arrayOf("arm64-v8a", "armeabi-v7a"), true),
    )
    assertEquals(
      "x86_64",
      selectSandboxAbi(arrayOf("x86_64", "x86"), true),
    )
  }

  @Test
  fun preservesAndroidPreferenceOrderForMixed64BitAbis() {
    assertEquals(
      "x86_64",
      selectSandboxAbi(arrayOf("x86_64", "arm64-v8a"), true),
    )
    assertEquals(
      "arm64-v8a",
      selectSandboxAbi(arrayOf("arm64-v8a", "x86_64"), true),
    )
  }

  @Test
  fun preservesAndroidPreferenceOrderForMixed32BitAbis() {
    assertEquals(
      "x86",
      selectSandboxAbi(arrayOf("x86", "armeabi-v7a"), false),
    )
    assertEquals(
      "armeabi-v7a",
      selectSandboxAbi(arrayOf("armeabi-v7a", "x86"), false),
    )
  }

  @Test
  fun preservesUnknownAbiAndHandlesAnEmptyList() {
    assertEquals("riscv64", selectSandboxAbi(arrayOf("riscv64"), true))
    assertEquals("unknown", selectSandboxAbi(emptyArray(), false))
  }

  @Test
  fun acceptsTheMatchingElfIdentityForEveryPublishedAbi() {
    assertTrue(
      elfHeaderMatchesSandboxAbi(elfHeader(elfClass = 1, machine = 40), "armeabi-v7a"),
    )
    assertTrue(
      elfHeaderMatchesSandboxAbi(elfHeader(elfClass = 2, machine = 183), "arm64-v8a"),
    )
    assertTrue(
      elfHeaderMatchesSandboxAbi(elfHeader(elfClass = 2, machine = 62), "x86_64"),
    )
  }

  @Test
  fun rejectsCrossArchitectureRootfsShells() {
    val arm64Shell = elfHeader(elfClass = 2, machine = 183)
    assertFalse(elfHeaderMatchesSandboxAbi(arm64Shell, "armeabi-v7a"))
    assertFalse(elfHeaderMatchesSandboxAbi(arm64Shell, "x86_64"))
  }

  @Test
  fun rejectsMalformedTruncatedAndUnknownElfHeaders() {
    assertFalse(elfHeaderMatchesSandboxAbi(ByteArray(20), "armeabi-v7a"))
    assertFalse(
      elfHeaderMatchesSandboxAbi(byteArrayOf(0x7f, 0x45, 0x4c, 0x46), "armeabi-v7a"),
    )
    assertFalse(
      elfHeaderMatchesSandboxAbi(elfHeader(elfClass = 1, machine = 40), "riscv64"),
    )
  }

  private fun elfHeader(elfClass: Int, machine: Int): ByteArray {
    return ByteArray(20).apply {
      this[0] = 0x7f.toByte()
      this[1] = 'E'.code.toByte()
      this[2] = 'L'.code.toByte()
      this[3] = 'F'.code.toByte()
      this[4] = elfClass.toByte()
      this[5] = 1 // Little endian.
      this[18] = (machine and 0xff).toByte()
      this[19] = ((machine shr 8) and 0xff).toByte()
    }
  }
}
