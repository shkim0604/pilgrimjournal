// Test-only RSA keys standing in for the keys behind Apple's Sign in with Apple JWKS
// (`openssl genrsa -traditional 2048`). They sign nothing outside these tests.

enum AppleTestKeys {
    static let firstKID = "test-kid-a"
    static let firstPrivateKeyPEM = """
        -----BEGIN RSA PRIVATE KEY-----
        MIIEowIBAAKCAQEAppLdlPL6DYmriV/3czZI8oIa5+hTELBuI6QZVhfdS+sM7Q2o
        ZfXKTmX92hEtsmOjQxUc71tRz1YzjL2ObT6yJJkBaVIwUPqe7SFmzMwzbOfJfkME
        5eFtv8xVorrbO4lZ3khGp+GTSax8N19DFR47jUjOhIfSxAXPkYHKS3Eco3wNtDqP
        lZGjhZsqe+L2aFQwROuggP/uCftPi6CZQThSeTBL/YIfGk3Ip8k1opKDhoudsd82
        8eOE4yLMJvYsxvDT+u4tU8NtNU+BYaAaiyCMbq3aWv63JbxJEepxJZbhTZ4NxYnY
        oYtbzux5gY+7WGlF0+9OI2N006IR5f6YUJk/9QIDAQABAoIBAAInVUoUYiXuqRMb
        nzK+zu6jvqlPmFNXlJ+irYPZcc5beaKkUeW6PyVdrYyLkFBazW+T7viBRmuB189y
        sUwO9XVXrRb+2F++Ux5fF4R/rLffFKcsl/xI5TGyTfZ5Uqr7DvhlbX8aLDIAUugn
        CSeqvmZd50hQtpQ7karLR3b2PW03q2EO0+2GssjKZLowyoa3DONJW3tDganCm6Um
        b5EYG/vhtn/w+1MzHxWPPvwEJpGO85ZpLFde8dd/tOjlSjOB5f9rkJWARr9qLhrx
        aj2DHcv5KERLC4ldAyutS/N1e+j3HAgT7/yeKusBCHct7k6Er9geETViIJr6K/0h
        vS1sYMECgYEA0uIQzi2Qsiujd7QXuRQlKGrdmc1l0h6QTcEnAHbegO043p3swRhf
        06bAww+i0ZBai+Oay8RZ+MJCMZzFVOM1UkDILUjhVE+CQ6Yb2iyUNi516dovtlKM
        HTbciQFoccFfCD4cODpXdrTQmOpPAPj1yTxyWK42mfHlKUghgxbhxOkCgYEAyjYA
        xYdv1EzsKXCGVw7Ss1tKOA/0d2H4YSJEm/QkUaZxklZGB4uQNnXBLutq/JLWSZbZ
        cNrFAGm5m11qhRFsf+s5iUmqofQ5i/ILPuF2MEG+NihktPgVOL1OEc7ADIRIyo7j
        1p4khq/Goxg9qR3kXyS1J/pPgIPYNfguKQQSqy0CgYAP9CZNUsklkYOWZLt+tvVw
        r1UAc7eGQ+Wq3Df1IwkGO+wXe18T5KIrQuxGVYJ91CvldVyamcostZWIZ1HOcDny
        dRAvzNmvJSy3rXNh+AlmZ/FntafyZSBQfXwFqWObZ4Om/fvojRFc26UETIWZjzwY
        80e7ScK7tr8ddmWCo1KFMQKBgAIlwKxYW9+tUXS/NS4HgkVVWtxtjvMVn0Woz4G4
        fgo/8kTTlbrOyKFLbtnItkIobQ4rA/Qm3qC6frYfr9np7XUOUnYayi0eIt5Rm7z3
        OAIbMKHym98wI0mO+R1HTNLVNNCx48mLtGeZxkpFH6KEJsC76xCZn+6Fd+5azGKz
        IF+hAoGBAMgeB6fWcDIeRSjZMJEI0bfSwhJeZ2etFUV9B6MRLFTLPFX5PETTrjIg
        nfqkjbH4A/UyeKd6QPr9oU4pfUMvK6XkG3/Mg363Slwfv5b2TKIATiu9kow5408l
        YzmyiDc7A5KpfxbX7P77wHMM+MeX8YhnCgqLFgDn9QIWrLzBNj7H
        -----END RSA PRIVATE KEY-----
        """
    static let firstModulus =
        "ppLdlPL6DYmriV_3czZI8oIa5-hTELBuI6QZVhfdS-sM7Q2oZfXKTmX92hEtsmOjQxUc71tRz1YzjL2ObT6yJJkBaVIwUPqe7SFmzMwzbOfJfkME5eFtv8xVorrbO4lZ3khGp-GTSax8N19DFR47jUjOhIfSxAXPkYHKS3Eco3wNtDqPlZGjhZsqe-L2aFQwROuggP_uCftPi6CZQThSeTBL_YIfGk3Ip8k1opKDhoudsd828eOE4yLMJvYsxvDT-u4tU8NtNU-BYaAaiyCMbq3aWv63JbxJEepxJZbhTZ4NxYnYoYtbzux5gY-7WGlF0-9OI2N006IR5f6YUJk_9Q"
    static let secondKID = "test-kid-b"
    static let secondPrivateKeyPEM = """
        -----BEGIN RSA PRIVATE KEY-----
        MIIEpAIBAAKCAQEA5Iq2AFeWOQTymj4hZJHzH0qiMjo/9pkIpvxP9vIwAyXfnY94
        baEH5lteD0NEvBdHKmFPpYvsDN9MpqezSvPFLQum5HI7qtWU8bB/SN6pE/wZghl3
        G8M+UT3N7U4zRfhu7AuADU2Bv77lsliQTgy4xooNPQhE4VPva4bTF1tywU0y+DuR
        3lODM3UykAZtVcdlJVp6u0KEALkvHpnUbl/eD8ApCLmiz4VFnulMjUR0Je+l+kjV
        AZzNUwImhFoDiRn9kMvGPg78ZpUZWsy4AgtKjEjnglneHiSKGiOwYec6LfzuTgtv
        4x2kbPfQOvTedM7xyXtjuMHkGj6lyI/lwo2vYQIDAQABAoIBAD48EbTFJSjQ0pmz
        GpfO8MRQKBwCZcGqycLjSYlHSVDKIvs+gv5jkAmoTtRcLp8DvcLqLey4TibxNefa
        GgZqnIKYPjHOc7YhJEaul/LJg4RoLbASbC94uwMXj/izx12h+d64gP3eYdtLyjQH
        TwCaEUUredBpbIxptXR0Cg69veGqNttHGWq5VYsblW6aKKcyHtkwz5/hiVGJ+Vv7
        9DEF8tbtefcCWymIizE+PCSEaE5XUfe83yrVikTgQ0aLle0WcG3srk9a95+6HGwF
        GY9bQ4vskxXwWfBO/eyCvH8/3EWHxYCoEqnKqnmXieOjddZJDKN7YchLIApqi7kM
        EA7kisMCgYEA9YATaBXbIt6cyuqPuirVmrNz9eQ6L1Y8cjlPDAIPsRNCTxF4ZFIw
        cHNzT0Dej+LbQP3qWqY6RXftlgRlvvuMMuq6s29JNa7hbxAjdtOxlp+auHNdwWSa
        gIMpwA2hG5y+u8UyFy1J0TIK7xibxMIhqAhpR5opBN5cmz7R2vyaJJsCgYEA7lD2
        BraUNxlOc+iEFju5Q/XW3ySxDj2FmNsIAapUcCKJNr8gkJPtooAuTAoKFs0uFMUw
        GKG8GLj7nfqx/xKYJer4Gnlu0A2X9revxBGKugovdsRJVnzrjjgrwAgDXeLBV4tm
        uMjqUhqg3Frad5CulIgoj/wvl7JyVLvhL0m2NbMCgYEAxviywd1U6gH6mgtZyc0F
        qohfJ599+PevrfP8uQLCrQWq7GKAbO6gC8PGZSlyOLPod9hTpHytJbh5eui9ffhq
        PKo5/0vmzfebBmTSGXChsi5RO8Vk62UaQ6YKpHlnZfW4MH82hcpS1ZX1fqs3NFUS
        6hlHGp07OZLvA3P6qb2pQJkCgYEAy9B/6NPjRJAnEWgM9zrSwnWQ87xclHI3PLgu
        S8ZReql+skyZXCy3cl+vuKZpZIDL5UWTUa2YwYgK4VxTOHO9ncgrsfCivdqyWXVV
        JBlgjKVDXI6YrhgeGL6fZBc2UegpNGbrTiO+isNtSaeF6fXZ6PvdvO6QAWvC7gbU
        mm2vIJMCgYB8RFG/46ohiF8A3fHcw8KnGWkpViyz07cB/Q6XC1CicTI6xfSi6xbg
        c5CtqbXrpNjytwDOPQ0sYV5ZNh91JQ/u6Ppl7q79VKjjCx5x8Syhs+hrpg5AkBZi
        13l+mW9yYQQTIMdCXWhQNVrstFa7n9FCy6/V5yG7AuUoFJEDOgJ6Ag==
        -----END RSA PRIVATE KEY-----
        """
    static let secondModulus =
        "5Iq2AFeWOQTymj4hZJHzH0qiMjo_9pkIpvxP9vIwAyXfnY94baEH5lteD0NEvBdHKmFPpYvsDN9MpqezSvPFLQum5HI7qtWU8bB_SN6pE_wZghl3G8M-UT3N7U4zRfhu7AuADU2Bv77lsliQTgy4xooNPQhE4VPva4bTF1tywU0y-DuR3lODM3UykAZtVcdlJVp6u0KEALkvHpnUbl_eD8ApCLmiz4VFnulMjUR0Je-l-kjVAZzNUwImhFoDiRn9kMvGPg78ZpUZWsy4AgtKjEjnglneHiSKGiOwYec6LfzuTgtv4x2kbPfQOvTedM7xyXtjuMHkGj6lyI_lwo2vYQ"
    static let exponent = "AQAB"
}
