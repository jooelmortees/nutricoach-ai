# Onboarding del usuario (para ti, Joel)

> Esta guía explica cómo configurar tu iPhone para que la app funcione al 100% desde el primer día.

## Requisitos

- iPhone con iOS 17 o superior
- Cuenta de Apple Developer Program activa (tienes)
- iPhone registrado en los provisioning profiles de la app y del widget
- Certificado Apple Development y ambos perfiles configurados en Codemagic
- FleckStore configurado con el certificado propio de NutriCoach
- App **"Health Sync by appyhapps"** (gratis) si quieres datos de tu Huawei Watch GT6 Pro

## Paso 1: Instalar la app

1. Ejecuta el workflow **`ios-signed`** en Codemagic.
2. Descarga `NutriCoach-Release.ipa`.
3. Abre el IPA en FleckStore, pulsa **Reset Settings** y deja **Remove mobileprovision** desactivado.
4. Firma e instala el IPA con el certificado propio de NutriCoach.
5. La app se instala como "NutriCoach" y la extensión queda incluida.
6. Ve a Ajustes > General > VPN y gestión de dispositivos y confía en el certificado si iOS lo solicita.

El IPA de GitHub Actions sirve para validar compilación. La firma final de FleckStore debe conservar HealthKit, App Groups, Keychain Sharing y `NutriCoachWidgets.appex`.

## Paso 2: Crear cuenta

1. Abre NutriCoach
2. Pulsa "Regístrate"
3. Pon tu email y una contraseña
4. Opcional: tu nombre
5. Ya estás dentro

## Paso 3: Conectar Apple Health

1. En la app, ve a la pestaña "Hoy" (Dashboard)
2. Pulsa "Conectar"
3. iOS te preguntará qué permisos dar
4. **Recomendado**: da TODOS los permisos (pasos, FC, sueño, entrenamientos, peso, etc.)
5. La app sincroniza los últimos 7 días automáticamente
6. A partir de ahí sincroniza cada vez que abres la app

## Paso 4: Configurar Huawei Watch GT6 Pro

> Importante: el Huawei Watch GT6 Pro no sincroniza con Apple Health directamente. Necesitas la app puente.

### Opción A: Health Sync by appyhapps (recomendado)

1. Instala "Health Sync by appyhapps" desde App Store (gratis)
2. Abre la app
3. En "Sources" selecciona **HUAWEI Health**
4. En "Targets" selecciona **Apple Health**
5. Marca qué quieres sincronizar:
   - Pasos ✅
   - FC reposo ✅
   - FC activa ✅
   - Sueño ✅
   - SpO2 ✅
   - Peso ✅
   - Calorías ✅
   - Entrenamientos ✅
6. Configura frecuencia: cada 15 minutos (o "realtime" si quieres)
7. Activa "Allow in background" en Ajustes > General > Actualización en segundo plano

### Opción B: Sincronización nativa de Huawei Health

1. Abre la app "HUAWEI Health" en tu iPhone
2. Perfil > Ajustes > Compartir datos > Apple Health
3. Activa TODOS los tipos de datos
4. Problema conocido: a veces se desincroniza por la gestión de batería agresiva de iOS
5. Truco: en Apple Health, ve a "Origenes" > Huawei Health > "Editar" > muévelo al TOPE de la lista

**Recomiendo Opción A** (Health Sync) porque es más fiable.

## Paso 5: Dar contexto al agente

1. Abre la pestaña "Chat"
2. Cuéntale al agente quién eres:
   - "Vivo con mis padres, no cocino yo"
   - "Quiero perder 5 kg en 3 meses"
   - "Soy alérgico a los frutos secos"
   - "Me gusta el deporte, corro 3 veces por semana"
   - "Tengo presupuesto de 50€/semana"
3. El agente va a guardar estos hechos automáticamente
4. A partir de ahí te conoce y personaliza todo

## Paso 6: Probar foto de comida

1. Ve a la pestaña "Cámara"
2. Toca el icono de foto o haz una foto de lo que comes
3. Pulsa "Enviar al agente"
4. El agente te dirá qué has comido, kcal, macros, y si te viene bien o no

## Renovación del certificado

FleckStore muestra la fecha de caducidad del certificado importado. Antes de renovarlo, genera de nuevo los perfiles de la app y del widget con el certificado vigente, súbelos a Codemagic y vuelve a importar el certificado correspondiente en FleckStore.

## Soporte

- Issues en GitHub
- Documentación técnica en `docs/`
- Logs en consola Xcode (necesitas Mac para verlos) o en el dashboard de Supabase
