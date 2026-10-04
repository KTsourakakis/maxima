package com.example.aura_straton_maxima_ai

import android.os.Handler
import android.os.Looper
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * PJSIP (pjsua2) SIP trunk client.
 *
 * The pjsua2 bindings are loaded reflectively so the application still
 * compiles and runs when the PJSIP binaries are not shipped. Once the
 * artifacts produced by `tools/build_pjsip.sh` (`pjsua2` classes +
 * `libpjsua2.so` per ABI) are packaged, this client registers against
 * the configured SIP trunk, injects `P-Preferred-Identity` /
 * `Remote-Party-ID` headers for SIM caller-ID passthrough, and places
 * calls over UDP/TLS.
 */
object MaximaSipClient {
    private const val PJSUA2_PACKAGE = "org.pjsip.pjsua2"

    private val endpointRef = AtomicReference<Any?>(null)
    private val accountRef = AtomicReference<Any?>(null)
    private val activeCallRef = AtomicReference<Any?>(null)
    private val workerLock = Any()
    private val mainHandler = Handler(Looper.getMainLooper())

    class SipException(message: String) : Exception(message)

    val isAvailable: Boolean
        get() = try {
            Class.forName("$PJSUA2_PACKAGE.Endpoint")
            true
        } catch (_: Throwable) {
            false
        }

    /**
     * Registers `username@server` against the SIP trunk.
     * Blocks the calling (background) thread; invoke from a worker.
     */
    fun register(
        server: String,
        username: String,
        password: String,
        callerId: String?,
        transport: String,
        port: Int,
    ): String = runBlocking {
        val ep = ensureEndpoint(transport, port)

        val accountConfig = newPjsua("AccountConfig")
        call(accountConfig, "setIdUri", arrayOf(String::class.java),
            "sip:$username@$server")

        val regConfig = call(accountConfig, "getRegConfig")
        call(regConfig, "setRegistrarUri", arrayOf(String::class.java),
            "sip:$server")
        call(regConfig, "setRegisterOnAdd", arrayOf(Boolean::class.java), true)

        val authCred = newPjsua(
            "AuthCredInfo",
            arrayOf(
                String::class.java, String::class.java, String::class.java,
                Int::class.java, String::class.java,
            ),
            "digest", "*", username, 0, password,
        )
        val credList = call(regConfig, "getCredInfoList")
        addToVector(credList, authCred)

        if (!callerId.isNullOrBlank()) {
            val sipConfig = call(accountConfig, "getSipConfig")
            val headers = call(sipConfig, "getHeaders")
            for (name in listOf("P-Preferred-Identity", "Remote-Party-ID")) {
                val header = newPjsua("SipHeaderOption")
                call(header, "setHName", arrayOf(String::class.java), name)
                call(
                    header, "setHValue", arrayOf(String::class.java),
                    "<sip:$callerId@$server>",
                )
                addToVector(headers, header)
            }
        }

        val account = newPjsua("Account")
        call(account, "create", arrayOf(classFor("AccountConfig")),
            accountConfig)
        accountRef.set(account)
        "registered:$username@$server"
    }

    /** Places an outbound call to `destination` through the trunk. */
    fun callDestination(destination: String): String = runBlocking {
        val account = accountRef.get()
            ?: throw SipException("SIP account is not registered")
        val invalidId = Class.forName("$PJSUA2_PACKAGE.pjsua2")
            .getField("PJSUA_INVALID_ID").getInt(null)
        val call = newPjsua(
            "Call",
            arrayOf(classFor("Account"), Int::class.java),
            account, invalidId,
        )
        val opParam = newPjsua(
            "CallOpParam",
            arrayOf(Boolean::class.java),
            true,
        )
        call(call, "makeCall", arrayOf(String::class.java, classFor("CallOpParam")),
            "sip:$destination", opParam)
        activeCallRef.set(call)
        "calling:$destination"
    }

    /** Hangs up the active call, if any. */
    fun hangup(): String = runBlocking {
        val call = activeCallRef.getAndSet(null)
            ?: return@runBlocking "no-active-call"
        val opParam = newPjsua("CallOpParam")
        call(call, "hangup", arrayOf(classFor("CallOpParam")), opParam)
        "hangup"
    }

    /** Runs [block] on a single worker thread, marshalling errors. */
    private fun <T> runBlocking(block: () -> T): T {
        synchronized(workerLock) {
            val result = AtomicReference<T?>()
            val failure = AtomicReference<Throwable?>()
            val latch = CountDownLatch(1)
            Thread({
                try {
                    result.set(block())
                } catch (error: Throwable) {
                    failure.set(error)
                } finally {
                    latch.countDown()
                }
            }, "maxima-sip").start()
            if (!latch.await(30, TimeUnit.SECONDS)) {
                throw SipException("SIP operation timed out")
            }
            failure.get()?.let {
                throw if (it is Exception) it else SipException(it.message ?: "SIP error")
            }
            @Suppress("UNCHECKED_CAST")
            return result.get() as T
        }
    }

    private fun ensureEndpoint(transport: String, port: Int): Any {
        endpointRef.get()?.let { return it }
        if (!isAvailable) {
            throw SipException("PJSIP_NOT_INSTALLED")
        }

        val epClass = classFor("Endpoint")
        val ep = epClass.getMethod("libCreate").invoke(null)
            ?: throw SipException("pjsua2 libCreate returned null")

        // libInit(EpConfig)
        val epConfig = newPjsua("EpConfig")
        epClass.getMethod("libInit", classFor("EpConfig")).invoke(ep, epConfig)

        // transportCreate(pjsip_transport_type_e, TransportConfig)
        val typeClass = classFor("pjsip_transport_type_e")
        val typeName = if (transport.equals("tls", true)) {
            "PJSIP_TRANSPORT_TLS"
        } else {
            "PJSIP_TRANSPORT_UDP"
        }
        val typeValue = typeClass.getField(typeName).get(null)
        val transportConfig = newPjsua("TransportConfig")
        call(transportConfig, "setPort", arrayOf(Int::class.java),
            if (port in 1..65535) port else 5060)
        epClass.getMethod(
            "transportCreate",
            typeClass,
            classFor("TransportConfig"),
        ).invoke(ep, typeValue, transportConfig)

        epClass.getMethod("libStart").invoke(ep)
        endpointRef.set(ep)
        return ep
    }

    private fun classFor(simpleName: String): Class<*> =
        Class.forName("$PJSUA2_PACKAGE.$simpleName")

    private fun newPjsua(
        simpleName: String,
        paramTypes: Array<Class<*>> = emptyArray(),
        vararg args: Any?,
    ): Any {
        val clazz = classFor(simpleName)
        return clazz.getConstructor(*paramTypes).newInstance(*args)
    }

    private fun call(
        target: Any?,
        method: String,
        paramTypes: Array<Class<*>> = emptyArray(),
        vararg args: Any?,
    ): Any? {
        val clazz = requireNotNull(target).javaClass
        return clazz.getMethod(method, *paramTypes).invoke(target, *args)
    }

    /** Invokes `vector.add(item)` on SWIG-generated typed vectors. */
    private fun addToVector(vector: Any?, item: Any) {
        val addMethod = requireNotNull(vector).javaClass.methods.firstOrNull {
            it.name == "add" && it.parameterCount == 1 &&
                it.parameterTypes[0].isAssignableFrom(item.javaClass)
        } ?: vector.javaClass.methods.firstOrNull {
            it.name == "add" && it.parameterCount == 1
        } ?: throw SipException("Vector type has no add() method")
        addMethod.invoke(vector, item)
    }

    /** Marshals a channel result through the SIP worker thread. */
    fun runAsync(
        block: () -> String,
        callback: (ok: Boolean, detail: String) -> Unit,
    ) {
        Thread({
            val (ok, detail) = try {
                true to block()
            } catch (error: Throwable) {
                false to (error.message ?: error.javaClass.simpleName)
            }
            mainHandler.post { callback(ok, detail) }
        }, "maxima-sip-call").start()
    }
}
