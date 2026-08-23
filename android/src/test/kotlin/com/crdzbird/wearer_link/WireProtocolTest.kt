package com.crdzbird.wearer_link

import kotlin.test.Test
import kotlin.test.assertEquals

/*
 * Run with `./gradlew testDebugUnitTest` in `example/android/`.
 */
internal class WireProtocolTest {
    @Test
    fun messagePathRoundTrips() {
        val wire = WireProtocol.messagePath("/workout/update")
        assertEquals("/wl/m/workout/update", wire)
        assertEquals("/workout/update", WireProtocol.userPathOfMessage(wire))
    }

    @Test
    fun syncPathRoundTrips() {
        val wire = WireProtocol.syncPath("/state")
        assertEquals("/wl/s/state", wire)
        assertEquals("/state", WireProtocol.userPathOfSync(wire))
    }

    @Test
    fun queuePathRoundTripsAndStripsId() {
        val wire = WireProtocol.queuePath("/note", "abc-123")
        assertEquals("/wl/q/note/abc-123", wire)
        assertEquals("/note", WireProtocol.userPathOfQueue(wire))
    }

    @Test
    fun filePathRoundTripsAndKeepsId() {
        val wire = WireProtocol.filePath("/photos/latest", "id-9")
        assertEquals("/wl/f/photos/latest/id-9", wire)
        assertEquals("/photos/latest", WireProtocol.userPathOfFile(wire))
        assertEquals("id-9", WireProtocol.idOfFile(wire))
    }
}
