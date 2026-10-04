package com.example.aura_straton_maxima_ai

import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager

class MaximaConnectionService : ConnectionService() {
    override fun onCreateOutgoingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?
    ): Connection {
        val connection = createMaximaConnection(request)
        connection.setInitializing()
        return connection
    }

    override fun onCreateIncomingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?
    ): Connection {
        val connection = createMaximaConnection(request)
        connection.setRinging()
        return connection
    }

    override fun onCreateOutgoingConnectionFailed(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?
    ) {
        super.onCreateOutgoingConnectionFailed(connectionManagerPhoneAccount, request)
    }

    private class MaximaConnection : Connection()

    private fun createMaximaConnection(request: ConnectionRequest?): Connection {
        return MaximaConnection().apply {
            audioModeIsVoip = true
            connectionCapabilities = Connection.CAPABILITY_MUTE or
                Connection.CAPABILITY_HOLD or
                Connection.CAPABILITY_SUPPORT_HOLD
            request?.address?.let {
                setAddress(it, TelecomManager.PRESENTATION_ALLOWED)
            }
            setCallerDisplayName(
                "Maxima Secure Call",
                TelecomManager.PRESENTATION_ALLOWED
            )
        }
    }
}
