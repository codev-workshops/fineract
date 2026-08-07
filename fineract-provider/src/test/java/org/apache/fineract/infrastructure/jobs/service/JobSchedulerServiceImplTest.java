/**
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements. See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership. The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License. You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied. See the License for the
 * specific language governing permissions and limitations
 * under the License.
 */
package org.apache.fineract.infrastructure.jobs.service;

import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

import org.apache.fineract.infrastructure.businessdate.service.BusinessDateReadPlatformService;
import org.apache.fineract.infrastructure.core.config.FineractProperties;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.mockito.junit.jupiter.MockitoSettings;
import org.mockito.quality.Strictness;
import org.springframework.context.event.ContextRefreshedEvent;

@ExtendWith(MockitoExtension.class)
@MockitoSettings(strictness = Strictness.LENIENT)
class JobSchedulerServiceImplTest {

    @Mock
    private FineractProperties fineractProperties;
    @Mock
    private SchedularWritePlatformService schedularWritePlatformService;
    @Mock
    private org.apache.fineract.infrastructure.core.service.tenant.TenantDetailsService tenantDetailsService;
    @Mock
    private JobRegisterService jobRegisterService;
    @Mock
    private BusinessDateReadPlatformService businessDateReadPlatformService;

    @InjectMocks
    private JobSchedulerServiceImpl jobSchedulerService;

    private FineractProperties.FineractModeProperties mode(boolean batchManager, boolean inAppScheduling) {
        FineractProperties.FineractModeProperties mode = new FineractProperties.FineractModeProperties();
        mode.setBatchManagerEnabled(batchManager);
        mode.setInAppSchedulingEnabled(inAppScheduling);
        return mode;
    }

    @Test
    void doesNotScheduleWhenNotBatchManager() {
        when(fineractProperties.getMode()).thenReturn(mode(false, true));

        jobSchedulerService.onApplicationEvent(new ContextRefreshedEvent(new org.springframework.context.support.StaticApplicationContext()));

        verifyNoInteractions(tenantDetailsService);
        verify(jobRegisterService, never()).scheduleJob(org.mockito.ArgumentMatchers.any());
    }

    @Test
    void doesNotScheduleWhenInAppSchedulingDisabledButStaysBatchManager() {
        // Batch manager stays enabled (executeJob API keeps working), but no in-app triggers are registered.
        when(fineractProperties.getMode()).thenReturn(mode(true, false));

        jobSchedulerService.onApplicationEvent(new ContextRefreshedEvent(new org.springframework.context.support.StaticApplicationContext()));

        verifyNoInteractions(tenantDetailsService);
        verify(jobRegisterService, never()).scheduleJob(org.mockito.ArgumentMatchers.any());
    }
}
